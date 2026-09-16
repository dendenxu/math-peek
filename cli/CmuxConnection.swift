import Darwin
import Foundation

struct CmuxConnectionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct CmuxConnectionRequest: Codable, Equatable {
    let version: Int
    let kind: String
    let socketPath: String
    let capability: String

    static func fromEnvironment(_ environment: [String: String]) throws -> Self {
        let instruction = "run math-peek connect cmux inside a local cmux terminal pane"
        guard let capability = environment["CMUX_SOCKET_CAPABILITY"], !capability.isEmpty else {
            throw CmuxConnectionError("\(instruction); this shell has no cmux connection capability. If cmux was updated, open a new pane first.")
        }
        guard capability.utf8.count <= 8192,
              capability.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw CmuxConnectionError("cmux supplied an invalid connection capability; open a new local cmux pane and retry")
        }
        let path = [environment["CMUX_SOCKET_PATH"], environment["CMUX_SOCKET"]]
            .compactMap { $0 }.first { !$0.isEmpty }
        guard let path else {
            throw CmuxConnectionError("\(instruction); this shell has no local cmux socket path")
        }
        guard path.hasPrefix("/"), path.utf8.count < 104,
              !path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }),
              !path.contains("://") else {
            throw CmuxConnectionError("cmux connection requires a local Unix socket path; remote and TCP sockets are not supported")
        }
        return Self(version: 1, kind: "cmux", socketPath: path, capability: capability)
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Math Peek/Connections", isDirectory: true)
    }

    func write(in directory: URL = Self.directory) throws -> URL {
        try Self.secureDirectory(directory.deletingLastPathComponent())
        try Self.secureDirectory(directory)
        var template = Array(directory.appendingPathComponent("cmux-XXXXXX.json").path.utf8CString)
        let descriptor = mkstemps(&template, 5)
        guard descriptor >= 0 else {
            throw CmuxConnectionError("could not create a private cmux connection request")
        }
        let url = URL(fileURLWithPath: String(cString: template))
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard fchmod(descriptor, 0o600) == 0 else {
                throw CmuxConnectionError("could not protect the cmux connection request")
            }
            try handle.write(contentsOf: JSONEncoder().encode(self))
            try handle.close()
            return url
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw CmuxConnectionError("could not save the private cmux connection request")
        }
    }

    static func openingURL(for request: URL) -> URL {
        var components = URLComponents()
        components.scheme = "mathpeek"
        components.host = "connect-cmux"
        components.queryItems = [URLQueryItem(name: "request", value: request.lastPathComponent)]
        return components.url!
    }

    private static func secureDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST {
            throw CmuxConnectionError("could not create the private cmux connection directory")
        }
        // Open the directory itself so a symlink cannot redirect credential writes.
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CmuxConnectionError("cmux connection directory must be a real directory, not a symlink")
        }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_uid == getuid(),
              fchmod(descriptor, 0o700) == 0 else {
            throw CmuxConnectionError("cmux connection directory must be owned by the current user and private")
        }
    }
}
