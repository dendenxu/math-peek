import Darwin
import Foundation

private let inputLimit = 2 * 1024 * 1024
private let usage = """
Usage: math-peek [--clipboard | --capture | --follow | FILE | -]
       math-peek connect cmux|ghostty

Preview UTF-8 text, Markdown, or LaTeX in Math Peek.
  --clipboard  Preview the Mac clipboard (default with terminal stdin).
  --capture    Preview the selected terminal's selection or visible text.
  --follow     Follow the selected terminal's visible text.
  --connect-cmux  Connect cmux for hover; run inside a local cmux pane.
  --connect-ghostty  Experimental hover; run in each local Ghostty pane.
  FILE         Open a local text file (up to 2 MB).
  -            Read UTF-8 text from stdin (also the default for a pipe).
  --           Treat remaining arguments as filenames.
  -h, --help   Show this help.
"""

private struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func boundedText(from handle: FileHandle) throws -> Data {
    var result = Data()
    while result.count <= inputLimit {
        guard let chunk = try handle.read(upToCount: min(65536, inputLimit + 1 - result.count)),
              !chunk.isEmpty else { break }
        result.append(chunk)
    }
    guard result.count <= inputLimit else {
        throw CLIError("input exceeds 2 MB; choose a smaller excerpt")
    }
    guard String(data: result, encoding: .utf8) != nil else {
        throw CLIError("input must be UTF-8 text")
    }
    return result
}

private func requestFile(containing data: Data) throws -> URL {
    let manager = FileManager.default
    let directory = manager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Math Peek/Requests", isDirectory: true)
    if let attributes = try? manager.attributesOfItem(atPath: directory.path),
       attributes[.type] as? FileAttributeType == .typeSymbolicLink {
        throw CLIError("request directory must not be a symlink")
    }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    var template = Array(directory.appendingPathComponent("math-peek-XXXXXX.md").path.utf8CString)
    let descriptor = mkstemps(&template, 3)
    guard descriptor >= 0 else { throw CLIError("could not create a preview request: \(String(cString: strerror(errno)))") }
    let url = URL(fileURLWithPath: String(cString: template))
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: data)
        try handle.close()
    } catch {
        try? manager.removeItem(at: url)
        throw error
    }
    return url
}

private func installedApplication() throws -> URL {
    let manager = FileManager.default
    var candidates: [URL] = []
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var executablePath = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&executablePath, &size) == 0 {
        let enclosingApp = URL(fileURLWithPath: String(cString: executablePath))
            .resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if enclosingApp.pathExtension == "app" { candidates.append(enclosingApp) }
    }
    candidates.append(manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Math Peek.app"))
    candidates.append(URL(fileURLWithPath: "/Applications/Math Peek.app"))
    guard let app = candidates.first(where: {
        manager.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/MathPeek").path)
    }) else {
        throw CLIError("Math Peek.app is not installed; install the release app or run ./install.sh first")
    }
    return app
}

private func run() throws -> Int32 {
    var file: String?
    var action: String?
    var literalArguments = false
    let arguments = Array(CommandLine.arguments.dropFirst())
    let normalizedArguments = arguments == ["connect", "cmux"] ? ["--connect-cmux"]
        : arguments == ["connect", "ghostty"] ? ["--connect-ghostty"] : arguments
    for argument in normalizedArguments {
        if !literalArguments && argument == "--" { literalArguments = true; continue }
        if !literalArguments && ["--help", "-h"].contains(argument) { print(usage); return 0 }
        if !literalArguments && argument == "--serve" {
            throw CLIError("--serve was removed; native hover, --capture, and --follow need no Python or iTerm RPC")
        }
        if !literalArguments && ["--clipboard", "--capture", "--follow", "--connect-cmux", "--connect-ghostty"].contains(argument) {
            guard action == nil, file == nil else { throw CLIError("choose only one action or file") }
            action = argument
        } else {
            guard literalArguments || argument == "-" || !argument.hasPrefix("-") else {
                throw CLIError("unknown option: \(argument)")
            }
            guard file == nil, action == nil else { throw CLIError("choose only one action or file") }
            file = argument
        }
    }
    let manager = FileManager.default
    let cmuxRequest = action == "--connect-cmux"
        ? try CmuxConnectionRequest.fromEnvironment(ProcessInfo.processInfo.environment) : nil
    let app = try installedApplication()
    if action == "--connect-ghostty" { return try GhosttyConnectCommand.run(application: app) }
    var request: URL?
    let target: String
    if let cmuxRequest {
        let url = try cmuxRequest.write()
        request = url
        target = CmuxConnectionRequest.openingURL(for: url).absoluteString
    } else if file == "-" || (file == nil && action == nil && isatty(STDIN_FILENO) == 0) {
        let url = try requestFile(containing: boundedText(from: .standardInput))
        request = url
        target = url.path
    } else if let file {
        let path = (file as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CLIError("file must be a regular text file: \(url.path)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = try boundedText(from: handle)
        target = url.path
    } else {
        target = "mathpeek://" + (action == "--capture" ? "capture" : action == "--follow" ? "follow" : "paste")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if cmuxRequest != nil {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CMUX_SOCKET_CAPABILITY")
        process.environment = environment
    }
    // Preserve the source terminal until the app resolves a capture/follow target.
    process.arguments = ["-g", "-a", app.path, target]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        if let request { try? manager.removeItem(at: request) }
        throw error
    }
    if process.terminationStatus != 0, let request { try? manager.removeItem(at: request) }
    if process.terminationStatus == 0, cmuxRequest != nil {
        print("Connection request sent to Math Peek. Check its menu for cmux connection status; no terminal refresh is needed.")
    }
    return process.terminationStatus
}

do {
    exit(try run())
} catch {
    FileHandle.standardError.write(Data("math-peek: \(error)\n".utf8))
    exit(2)
}
