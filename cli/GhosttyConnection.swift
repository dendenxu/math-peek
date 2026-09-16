import Darwin
import Foundation
#if canImport(TerminalBridge)
import TerminalBridge
#endif

private var ghosttyQuerySignal: Int32 = 0

enum GhosttyConnectCommand {
    static func parseCellReport(_ bytes: [UInt8]) -> (height: Int, width: Int)? {
        guard bytes.count <= 64, let value = String(bytes: bytes, encoding: .ascii),
              value.hasPrefix("\u{1b}[6;"), value.hasSuffix("t") else { return nil }
        let fields = value.dropFirst(4).dropLast().split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let height = Int(fields[0]), let width = Int(fields[1]),
              (2...1024).contains(height), (2...512).contains(width) else { return nil }
        return (height, width)
    }

    static func cellSize(_ descriptor: Int32) throws -> (height: Int, width: Int) {
        var pending: Int32 = 0
        let pendingBytesRequest: UInt = 0x4004667f // Darwin FIONREAD is not imported by Swift.
        guard ioctl(descriptor, pendingBytesRequest, &pending) == 0, pending == 0 else {
            throw GhosttyConnectionError("Terminal input is pending; wait and retry without typing during the brief size query.")
        }
        var original = termios()
        guard tcgetattr(descriptor, &original) == 0 else { throw GhosttyConnectionError("Could not read terminal settings.") }
        var queryMode = original
        queryMode.c_lflag &= ~tcflag_t(ICANON | ECHO)
        ghosttyQuerySignal = 0
        let interrupt = signal(SIGINT) { ghosttyQuerySignal = $0 }
        let terminate = signal(SIGTERM) { ghosttyQuerySignal = $0 }
        let hangup = signal(SIGHUP) { ghosttyQuerySignal = $0 }
        defer {
            tcsetattr(descriptor, TCSANOW, &original)
            signal(SIGINT, interrupt); signal(SIGTERM, terminate); signal(SIGHUP, hangup)
        }
        guard tcsetattr(descriptor, TCSANOW, &queryMode) == 0 else { throw GhosttyConnectionError("Could not query terminal dimensions.") }
        let query = Array("\u{1b}[16t".utf8)
        guard query.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == query.count else {
            throw GhosttyConnectionError("Could not send the cell-size query.")
        }
        var bytes: [UInt8] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while ProcessInfo.processInfo.systemUptime < deadline, bytes.count < 64, ghosttyQuerySignal == 0 {
            var descriptorEvent = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptorEvent, 1, 10) <= 0 { continue }
            var byte: UInt8 = 0
            if Darwin.read(descriptor, &byte, 1) == 1 {
                bytes.append(byte)
                if byte == UInt8(ascii: "t") { break }
            }
        }
        guard ghosttyQuerySignal == 0 else { throw GhosttyConnectionError("Connection cancelled.") }
        guard let dimensions = parseCellReport(bytes) else {
            throw GhosttyConnectionError("Ghostty did not return a valid cell size. Run directly in a local Ghostty pane and avoid typing while connecting.")
        }
        return dimensions
    }

    static func run(application: URL) throws -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard ["TMUX", "STY", "SSH_CONNECTION", "SSH_TTY"].allSatisfy({ environment[$0]?.isEmpty != false }),
              let client = TerminalProcess.read(getpid()),
              let ghostty = TerminalProcess.ghosttyAncestor(of: client.pid),
              let tty = ttyname(STDIN_FILENO), isatty(STDOUT_FILENO) == 1 else {
            throw GhosttyConnectionError("Run math-peek connect ghostty directly in a local Ghostty pane, outside tmux, screen, or SSH.")
        }
        let path = String(cString: tty)
        let descriptor = open(path, O_RDWR | O_NOCTTY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GhosttyConnectionError("Could not open this terminal.") }
        defer { close(descriptor) }
        var input = stat(), output = stat()
        guard fstat(descriptor, &input) == 0, fstat(STDOUT_FILENO, &output) == 0,
              input.st_rdev == output.st_rdev, tcgetpgrp(descriptor) == getpgrp(),
              TerminalProcess.isDirectSession(tcgetsid(descriptor), device: UInt32(bitPattern: input.st_rdev), ghostty: ghostty),
              let dimensions = TerminalDimensions.read(descriptor) else {
            throw GhosttyConnectionError("Connection requires the foreground shell of a local Ghostty pane.")
        }
        print("Connecting experimental Ghostty hover (ordinary output; redraws and hidden text are not reliable).")
        fflush(stdout)
        let cell = try cellSize(descriptor)
        let request = GhosttyConnectionRequest(client: client, ghostty: ghostty, ttyPath: path,
            ttyDevice: UInt32(bitPattern: input.st_rdev), session: tcgetsid(descriptor), dimensions: dimensions,
            cellWidthPixels: cell.width, cellHeightPixels: cell.height)
        try request.validate()
        let name = try GhosttyConnectionFiles.writeRequest(request)
        defer { GhosttyConnectionFiles.remove(name) }
        print(request.marker)
        fflush(stdout)
        var url = URLComponents()
        url.scheme = "mathpeek"; url.host = "connect-ghostty"
        url.queryItems = [URLQueryItem(name: "request", value: name)]
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-g", "-a", application.path, url.url!.absoluteString]
        try launch.run(); launch.waitUntilExit()
        guard launch.terminationStatus == 0 else { throw GhosttyConnectionError("Could not open Math Peek.") }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let reply = try GhosttyConnectionFiles.consumeReply(for: name) {
                guard reply.connected else { throw GhosttyConnectionError(reply.message) }
                print(reply.message)
                print("No refresh needed. New output can lag by about 500 ms in Ghostty. Reconnect each new pane and after restarting Math Peek; use Terminal Apps > Disconnect Ghostty to stop.")
                return 0
            }
            usleep(40_000)
        }
        throw GhosttyConnectionError("Math Peek did not confirm pairing. Update Math Peek, allow Accessibility, keep this pane visible, and retry. No connection was confirmed.")
    }
}
