import Darwin
import Foundation

public struct GhosttyConnectionError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public var errorDescription: String? { description }
    public init(_ message: String) { description = message }
}

public struct TerminalProcess: Codable, Equatable {
    public let pid: Int32
    public let parent: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let ttyDevice: UInt32

    public static func read(_ pid: Int32) -> Self? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
           info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) {
            return Self(pid: pid, parent: Int32(info.pbi_ppid), startSeconds: info.pbi_start_tvsec,
                        startMicroseconds: info.pbi_start_tvusec, ttyDevice: info.e_tdev)
        }
        // Ghostty starts shells through macOS's setuid login helper. libproc
        // hides that helper's BSD info; sysctl still exposes ordinary ps metadata.
        var kernel = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &kernel, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, kernel.kp_proc.p_pid == pid,
              kernel.kp_proc.p_stat != SZOMB,
              kernel.kp_eproc.e_ucred.cr_uid == getuid() ||
                (kernel.kp_eproc.e_ucred.cr_uid == 0 && path(pid) == "/usr/bin/login"),
              kernel.kp_proc.p_un.__p_starttime.tv_sec > 0 else { return nil }
        return Self(pid: pid, parent: kernel.kp_eproc.e_ppid,
                    startSeconds: UInt64(kernel.kp_proc.p_un.__p_starttime.tv_sec),
                    startMicroseconds: UInt64(kernel.kp_proc.p_un.__p_starttime.tv_usec),
                    ttyDevice: UInt32(bitPattern: kernel.kp_eproc.e_tdev))
    }

    public func isAlive() -> Bool {
        guard let current = Self.read(pid) else { return false }
        return current.startSeconds == startSeconds && current.startMicroseconds == startMicroseconds
    }

    public static func path(_ pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }

    public static func ghosttyAncestor(of pid: Int32) -> Self? {
        var current = pid
        for _ in 0..<32 {
            guard let info = read(current) else { return nil }
            if path(current)?.hasSuffix("/Contents/MacOS/ghostty") == true { return info }
            guard info.parent != current else { return nil }
            current = info.parent
        }
        return nil
    }

    // A nonce printed through tmux/SSH can reach Ghostty too. Require the local
    // controlling session, not just matching dimensions or a matching environment.
    public static func isDirectSession(_ session: Int32, device: UInt32, ghostty: TerminalProcess) -> Bool {
        guard ghostty.isAlive() else { return false }
        var current = session
        for _ in 0..<8 {
            guard current != ghostty.pid, let process = read(current), process.ttyDevice == device else { return false }
            if process.parent == ghostty.pid { return true }
            guard process.parent != current else { return false }
            current = process.parent
        }
        return false
    }
}

public struct TerminalDimensions: Codable, Equatable {
    public let columns: Int
    public let rows: Int
    public let widthPixels: Int
    public let heightPixels: Int

    public init(columns: Int, rows: Int, widthPixels: Int, heightPixels: Int) {
        self.columns = columns; self.rows = rows
        self.widthPixels = widthPixels; self.heightPixels = heightPixels
    }

    public var valid: Bool {
        (2...1024).contains(columns) && (2...512).contains(rows) &&
            (columns...65535).contains(widthPixels) && (rows...65535).contains(heightPixels)
    }

    public static func read(_ descriptor: Int32) -> Self? {
        var value = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &value) == 0 else { return nil }
        let dimensions = Self(columns: Int(value.ws_col), rows: Int(value.ws_row),
                              widthPixels: Int(value.ws_xpixel), heightPixels: Int(value.ws_ypixel))
        return dimensions.valid ? dimensions : nil
    }
}

public struct GhosttyConnectionRequest: Codable {
    public let version: Int
    public let nonce: String
    public let client: TerminalProcess
    public let ghostty: TerminalProcess
    public let ttyPath: String
    public let ttyDevice: UInt32
    public let session: Int32
    public let dimensions: TerminalDimensions
    public let cellWidthPixels: Int
    public let cellHeightPixels: Int
    public var marker: String { "MATHPEEK-GHOSTTY-" + nonce }

    public init(client: TerminalProcess, ghostty: TerminalProcess, ttyPath: String, ttyDevice: UInt32,
                session: Int32, dimensions: TerminalDimensions, cellWidthPixels: Int, cellHeightPixels: Int) {
        version = 1; nonce = UUID().uuidString
        self.client = client; self.ghostty = ghostty; self.ttyPath = ttyPath
        self.ttyDevice = ttyDevice; self.session = session; self.dimensions = dimensions
        self.cellWidthPixels = cellWidthPixels; self.cellHeightPixels = cellHeightPixels
    }

    public func validate() throws {
        guard version == 1, UUID(uuidString: nonce)?.uuidString == nonce,
              ttyPath.range(of: "\\A/dev/ttys[0-9A-Za-z]{1,12}\\z", options: .regularExpression) != nil,
              dimensions.valid, (2...512).contains(cellWidthPixels), (2...1024).contains(cellHeightPixels),
              dimensions.widthPixels / cellWidthPixels == dimensions.columns,
              dimensions.heightPixels / cellHeightPixels == dimensions.rows,
              client.isAlive(), ghostty.isAlive(), client.ttyDevice == ttyDevice,
              TerminalProcess.read(client.pid)?.ttyDevice == ttyDevice,
              TerminalProcess.ghosttyAncestor(of: client.pid) == ghostty,
              TerminalProcess.isDirectSession(session, device: ttyDevice, ghostty: ghostty) else {
            throw GhosttyConnectionError("Run the connection command in a local Ghostty pane, outside tmux, screen, or SSH.")
        }
    }

    public func openVerifiedTTY() throws -> Int32 {
        try validate()
        let descriptor = open(ttyPath, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { throw GhosttyConnectionError("The originating terminal is no longer available.") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFCHR,
              UInt32(bitPattern: metadata.st_rdev) == ttyDevice, tcgetsid(descriptor) == session,
              TerminalDimensions.read(descriptor) == dimensions else {
            close(descriptor)
            throw GhosttyConnectionError("Terminal identity or dimensions changed during pairing; retry in the same pane.")
        }
        return descriptor
    }
}

public struct GhosttyConnectionReply: Codable {
    public let connected: Bool
    public let message: String
    public init(connected: Bool, message: String) { self.connected = connected; self.message = message }
}

public enum GhosttyConnectionFiles {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Math Peek/Ghostty")
    }

    private static func openDirectory(_ directory: URL, create: Bool) throws -> Int32 {
        if create {
            let parent = directory.deletingLastPathComponent()
            for url in [parent, directory] {
                if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw GhosttyConnectionError("Could not create the private connection directory.") }
                let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw GhosttyConnectionError("Connection directory must not be a symlink.") }
                var metadata = stat()
                let valid = fstat(fd, &metadata) == 0 && metadata.st_uid == getuid() && fchmod(fd, 0o700) == 0
                close(fd)
                guard valid else { throw GhosttyConnectionError("Connection directory must belong to this user.") }
            }
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var metadata = stat()
        guard fd >= 0 else { throw GhosttyConnectionError("Connection directory is unavailable.") }
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            close(fd); throw GhosttyConnectionError("Connection directory must be private.")
        }
        return fd
    }

    public static func validName(_ name: String) -> Bool {
        guard name.hasPrefix("ghostty-"), name.hasSuffix(".json") else { return false }
        return UUID(uuidString: String(name.dropFirst(8).dropLast(5)))?.uuidString == String(name.dropFirst(8).dropLast(5))
    }

    private static func write(_ data: Data, name: String, directory: URL) throws {
        let folder = try openDirectory(directory, create: true)
        defer { close(folder) }
        let temporary = ".pending-" + UUID().uuidString
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GhosttyConnectionError("Could not create a private connection message.") }
        defer { close(fd); unlinkat(folder, temporary, 0) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GhosttyConnectionError("Could not write the connection message.") }
            offset += count
        }
        guard renameatx_np(folder, temporary, folder, name, UInt32(RENAME_EXCL)) == 0 else {
            throw GhosttyConnectionError("Connection message already exists or could not be published.")
        }
    }

    private static func consume(_ name: String, directory: URL) throws -> Data? {
        let folder = try openDirectory(directory, create: false)
        defer { close(folder) }
        let fd = openat(folder, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw GhosttyConnectionError("Connection message is unavailable.") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1,
              metadata.st_size > 0, metadata.st_size <= 8192 else {
            throw GhosttyConnectionError("Invalid connection message.")
        }
        var data = Data(count: Int(metadata.st_size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GhosttyConnectionError("Incomplete connection message.") }
            offset += count
        }
        guard unlinkat(folder, name, 0) == 0 else { throw GhosttyConnectionError("Connection message was already consumed.") }
        return data
    }

    public static func writeRequest(_ request: GhosttyConnectionRequest, in directory: URL = directory) throws -> String {
        let name = "ghostty-\(request.nonce).json"
        guard validName(name) else { throw GhosttyConnectionError("Invalid pairing nonce.") }
        try write(JSONEncoder().encode(request), name: name, directory: directory)
        return name
    }

    public static func consumeRequest(_ name: String, in directory: URL = directory) throws -> GhosttyConnectionRequest {
        guard validName(name), let data = try consume(name, directory: directory) else { throw GhosttyConnectionError("Invalid or expired connection request.") }
        let request = try JSONDecoder().decode(GhosttyConnectionRequest.self, from: data)
        guard name == "ghostty-\(request.nonce).json" else { throw GhosttyConnectionError("Invalid pairing nonce.") }
        return request
    }

    public static func writeReply(_ reply: GhosttyConnectionReply, for name: String, in directory: URL = directory) throws {
        guard validName(name) else { throw GhosttyConnectionError("Invalid connection name.") }
        try write(JSONEncoder().encode(reply), name: name + ".reply", directory: directory)
    }

    public static func consumeReply(for name: String, in directory: URL = directory) throws -> GhosttyConnectionReply? {
        guard validName(name) else { throw GhosttyConnectionError("Invalid connection name.") }
        guard let data = try consume(name + ".reply", directory: directory) else { return nil }
        return try JSONDecoder().decode(GhosttyConnectionReply.self, from: data)
    }

    public static func remove(_ name: String, in directory: URL = directory) {
        guard validName(name), let folder = try? openDirectory(directory, create: false) else { return }
        defer { close(folder) }
        unlinkat(folder, name, 0); unlinkat(folder, name + ".reply", 0)
    }
}
