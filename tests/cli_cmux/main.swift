import Darwin
import Foundation

var checks = 0
var failures = 0
func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL \(name)") }
}
func rejected(_ environment: [String: String], _ name: String) {
    do {
        _ = try CmuxConnectionRequest.fromEnvironment(environment)
        check(false, name)
    } catch {
        check(!String(describing: error).contains("fixture-secret"), name + " without disclosing capability")
    }
}

let fixtureCapability = "fixture-secret.only-for-local-test"
let environment = ["CMUX_SOCKET_CAPABILITY": fixtureCapability, "CMUX_SOCKET_PATH": "/tmp/cmux-fixture.sock"]
let request = try CmuxConnectionRequest.fromEnvironment(environment)
check(request.version == 1 && request.kind == "cmux" && request.socketPath == "/tmp/cmux-fixture.sock", "versioned local connection")
check(request.capability == fixtureCapability, "capability preserved exactly")
var competing = environment
competing["CMUX_SOCKET"] = "/tmp/other-fixture.sock"
check(try CmuxConnectionRequest.fromEnvironment(competing).socketPath == request.socketPath, "primary socket environment wins")
competing.removeValue(forKey: "CMUX_SOCKET_PATH")
check(try CmuxConnectionRequest.fromEnvironment(competing).socketPath == "/tmp/other-fixture.sock", "legacy socket environment supported")
rejected([:], "outside cmux rejected")
rejected(["CMUX_SOCKET_CAPABILITY": fixtureCapability], "missing path rejected")
for invalidPath in ["relative.sock", "localhost:1234", "unix:///tmp/cmux.sock", "/tmp/bad\n.sock", "/tmp/bad\0.sock", "/" + String(repeating: "x", count: 103)] {
    var invalid = environment
    invalid["CMUX_SOCKET_PATH"] = invalidPath
    rejected(invalid, "non-local or malformed socket rejected")
}
for invalidCapability in ["", "fixture-secret with-space", "fixture-secret\nline", "fixture-secret\0zero", "fixture-secret\u{7f}", "fixture-secret\u{e9}", String(repeating: "x", count: 8193)] {
    var invalid = environment
    invalid["CMUX_SOCKET_CAPABILITY"] = invalidCapability
    rejected(invalid, "malformed capability rejected")
}
var limit = environment
limit["CMUX_SOCKET_CAPABILITY"] = String(repeating: "x", count: 8192)
check(try CmuxConnectionRequest.fromEnvironment(limit).capability.utf8.count == 8192, "bounded capability limit accepted")

let manager = FileManager.default
let fixtureRoot = manager.temporaryDirectory.appendingPathComponent("math-peek-cmux-tests-" + UUID().uuidString, isDirectory: true)
try manager.createDirectory(at: fixtureRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? manager.removeItem(at: fixtureRoot) }
let privateRoot = fixtureRoot.appendingPathComponent("Math Peek", isDirectory: true)
let directory = privateRoot.appendingPathComponent("Connections", isDirectory: true)
let file = try request.write(in: directory)
check(file.lastPathComponent.hasPrefix("cmux-") && file.pathExtension == "json", "request uses bounded recognizable basename")
check(try JSONDecoder().decode(CmuxConnectionRequest.self, from: Data(contentsOf: file)) == request, "request JSON round trip")
let fileAttributes = try manager.attributesOfItem(atPath: file.path)
let directoryAttributes = try manager.attributesOfItem(atPath: directory.path)
check((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "credential handoff file is owner-only")
check((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "handoff directory is owner-only")
let openingURL = CmuxConnectionRequest.openingURL(for: file)
let components = URLComponents(url: openingURL, resolvingAgainstBaseURL: false)!
check(components.scheme == "mathpeek" && components.host == "connect-cmux", "request opens connection endpoint")
check(components.queryItems == [URLQueryItem(name: "request", value: file.lastPathComponent)], "only basename crosses URL handoff")
check(!openingURL.absoluteString.contains(fixtureCapability), "capability absent from launch URL")
let second = try request.write(in: directory)
check(second != file, "requests use distinct unpredictable names")

let symlink = privateRoot.appendingPathComponent("LinkedConnections", isDirectory: true)
try manager.createSymbolicLink(at: symlink, withDestinationURL: directory)
do {
    _ = try request.write(in: symlink)
    check(false, "symlink request directory rejected")
} catch {
    check(true, "symlink request directory rejected")
}
let linkedParent = fixtureRoot.appendingPathComponent("LinkedParent", isDirectory: true)
try manager.createSymbolicLink(at: linkedParent, withDestinationURL: privateRoot)
do {
    _ = try request.write(in: linkedParent.appendingPathComponent("Connections"))
    check(false, "symlink Math Peek parent rejected")
} catch {
    check(true, "symlink Math Peek parent rejected")
}
print("cmux CLI pairing: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
