import Darwin
import Foundation

struct CmuxSocket {
    struct Connection: Codable, Equatable {
        let version: Int
        let kind: String
        let socketPath: String
        let capability: String

        init(socketPath: String, capability: String) {
            version = 1
            kind = "cmux"
            self.socketPath = socketPath
            self.capability = capability
        }

        func validate() throws {
            guard version == 1, kind == "cmux", socketPath.hasPrefix("/"),
                  socketPath.utf8.count < 104,
                  !socketPath.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }),
                  !socketPath.contains("://"), !capability.isEmpty,
                  capability.utf8.count <= 8192,
                  capability.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
                throw Failure.invalidConnection
            }
        }
    }

    enum Method: String {
        case systemCapabilities = "system.capabilities"
        case debugTerminals = "debug.terminals"
        case paneList = "pane.list"
        case mobileTerminalReplay = "mobile.terminal.replay"
        case mobileHostStatus = "mobile.host.status"
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case invalidConnection, invalidRequest, unavailable, timeout
        case unexpectedPeer, invalidResponse, rejected, responseTooLarge

        var description: String {
            switch self {
            case .invalidConnection: return "The cmux connection details are invalid. Reconnect from a local cmux pane."
            case .invalidRequest: return "The cmux read request is invalid."
            case .unavailable: return "The cmux connection is unavailable."
            case .timeout: return "The cmux read request timed out."
            case .unexpectedPeer: return "The cmux connection belongs to an unexpected process."
            case .invalidResponse: return "cmux returned an invalid read response."
            case .rejected: return "cmux rejected the read request. Reconnect from a local cmux pane if needed."
            case .responseTooLarge: return "The cmux read response exceeds 2 MB."
            }
        }
    }

    let connection: Connection
    let expectedPID: pid_t?
    static let responseLimit = 2 * 1024 * 1024

    init(connection: Connection, expectedPID: pid_t? = nil) {
        self.connection = connection
        self.expectedPID = expectedPID
    }

    // Call from a worker queue: one deadline bounds connect, write, and read together.
    func call(_ method: Method, params: [String: Any] = [:], timeout: TimeInterval = 0.15) throws -> [String: Any] {
        try connection.validate()
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw Failure.invalidRequest }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        let identifier = UUID().uuidString
        let object: [String: Any] = ["id": identifier, "method": method.rawValue, "params": params]
        guard JSONSerialization.isValidJSONObject(object),
              let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              json.count <= Self.responseLimit else { throw Failure.invalidRequest }
        var command = Data("_cmux_capability_v1 \(connection.capability) ".utf8)
        command.append(json)
        command.append(10)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        var noSignal: Int32 = 1
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) >= 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Failure.unavailable
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        connection.socketPath.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    _ = strcpy(destination, path)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EWOULDBLOCK else { throw Failure.unavailable }
            try wait(descriptor, for: Int16(POLLOUT), until: deadline)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else { throw Failure.unavailable }
        }
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else { throw Failure.unexpectedPeer }
        if let expectedPID {
            var process: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &process, &length) == 0,
                  process == expectedPID else { throw Failure.unexpectedPeer }
        }

        var sent = 0
        while sent < command.count {
            try wait(descriptor, for: Int16(POLLOUT), until: deadline)
            let count = command.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: sent), command.count - sent, 0)
            }
            if count > 0 { sent += count }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            else { throw Failure.unavailable }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try wait(descriptor, for: Int16(POLLIN), until: deadline)
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            guard count > 0 else { throw Failure.invalidResponse }
            let end = buffer.prefix(count).firstIndex(of: 10).map { response.count + $0 }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= Self.responseLimit else { throw Failure.responseTooLarge }
            guard let end else { continue }
            guard let responseObject = try? JSONSerialization.jsonObject(with: response[..<end]),
                  let envelope = responseObject as? [String: Any],
                  envelope["id"] as? String == identifier,
                  let ok = envelope["ok"] as? NSNumber,
                  CFGetTypeID(ok) == CFBooleanGetTypeID() else { throw Failure.invalidResponse }
            guard ok.boolValue else { throw Failure.rejected }
            guard let result = envelope["result"] as? [String: Any] else { throw Failure.invalidResponse }
            return result
        }
    }

    private func wait(_ descriptor: Int32, for events: Int16, until deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw Failure.timeout }
            let milliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw Failure.unavailable }
            if result == 0 { continue }
            guard item.revents & Int16(POLLNVAL) == 0 else { throw Failure.unavailable }
            if item.revents & (events | Int16(POLLHUP)) != 0 { return }
            throw Failure.unavailable
        }
    }
}
