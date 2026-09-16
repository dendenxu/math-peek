import Darwin
import Foundation

var checks = 0
var failures = 0
func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL \(name)") }
}

let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("math-peek-connection-store-" + UUID().uuidString, isDirectory: true)
try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? manager.removeItem(at: root) }
let directory = root.appendingPathComponent("Connections", isDirectory: true)
try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let fakeCapability = "fixture-secret.only-for-local-test"
let connection = CmuxSocket.Connection(socketPath: "/tmp/cmux-fixture.sock", capability: fakeCapability)
let validData = try JSONEncoder().encode(connection)

func write(_ name: String = "cmux-AbC123.json", data: Data = validData, mode: mode_t = 0o600, in folder: URL = directory) throws -> URL {
    let file = folder.appendingPathComponent(name)
    try data.write(to: file, options: .withoutOverwriting)
    guard chmod(file.path, mode) == 0 else { throw CmuxConnectionStore.Failure.invalidRequest }
    return file
}

func rejected(_ name: String, in folder: URL = directory, label: String) {
    do {
        _ = try CmuxConnectionStore.consume(name, in: folder)
        check(false, label)
    } catch {
        check(true, label)
        check(!String(describing: error).contains(fakeCapability), "rejection does not disclose request credentials")
    }
}

do {
    let file = try write()
    let received = try CmuxConnectionStore.consume(file.lastPathComponent, in: directory)
    check(received == connection, "valid request imports exact connection")
    check(!manager.fileExists(atPath: file.path), "successful request is unlinked")
    rejected(file.lastPathComponent, label: "request cannot be replayed")
}
do {
    let file = try write(mode: 0o400)
    check(try CmuxConnectionStore.consume(file.lastPathComponent, in: directory) == connection,
          "owner-readable private request can be consumed")
}
for (label, data) in [
    ("invalid JSON rejected", Data("not-json fixture-secret.only-for-local-test".utf8)),
    ("invalid UTF-8 rejected", Data([0xff, 0xfe, 0x80])),
    ("truncated JSON rejected", validData.dropLast()),
    ("trailing data rejected", validData + Data("garbage".utf8)),
    ("array schema rejected", Data("[]".utf8)),
    ("missing fields rejected", Data("{\"version\":1,\"kind\":\"cmux\"}".utf8))
] {
    let file = try write(data: data)
    rejected(file.lastPathComponent, label: label)
    check(!manager.fileExists(atPath: file.path), "malformed request is unlinked before parsing")
}
for (key, value) in [
    ("version", 2 as Any), ("kind", "other" as Any),
    ("socketPath", "localhost:1234" as Any), ("socketPath", "/tmp/nul\0.sock" as Any),
    ("capability", "fixture-secret with-space" as Any), ("capability", "" as Any)
] {
    var object = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
    object[key] = value
    let file = try write(data: JSONSerialization.data(withJSONObject: object))
    rejected(file.lastPathComponent, label: "invalid connection value rejected")
    check(!manager.fileExists(atPath: file.path), "invalid connection request is unlinked")
}
do {
    let file = try write(data: validData + Data(repeating: 0x20, count: 16_384 - validData.count))
    check(try CmuxConnectionStore.consume(file.lastPathComponent, in: directory) == connection, "maximum request byte size accepted")
}
for data in [Data(), Data(repeating: 0x20, count: 16_385)] {
    let file = try write(data: data)
    rejected(file.lastPathComponent, label: "empty or oversized request rejected")
    try? manager.removeItem(at: file)
}
for permissions: mode_t in [0o640, 0o604, 0o601, 0o666] {
    let file = try write(mode: permissions)
    rejected(file.lastPathComponent, label: "non-private request permissions rejected")
    check(manager.fileExists(atPath: file.path), "unsafe file is not consumed")
    try manager.removeItem(at: file)
}
do {
    let file = try write()
    guard chmod(directory.path, 0o755) == 0 else { fatalError("fixture chmod failed") }
    rejected(file.lastPathComponent, label: "non-private connection directory rejected")
    check(manager.fileExists(atPath: file.path), "unsafe directory request remains untouched")
    guard chmod(directory.path, 0o700) == 0 else { fatalError("fixture chmod failed") }
    try manager.removeItem(at: file)
}
do {
    let destination = try write("target.json")
    let link = directory.appendingPathComponent("cmux-AbC123.json")
    try manager.createSymbolicLink(at: link, withDestinationURL: destination)
    rejected(link.lastPathComponent, label: "request symlink rejected")
    check(try Data(contentsOf: destination) == validData, "symlink target remains untouched")
    try manager.removeItem(at: link)
    try manager.removeItem(at: destination)
}
do {
    let destination = try write("target.json")
    let link = directory.appendingPathComponent("cmux-AbC123.json")
    try manager.linkItem(at: destination, to: link)
    rejected(link.lastPathComponent, label: "multiply-linked request rejected")
    check(try Data(contentsOf: destination) == validData, "hardlink target remains untouched")
    try manager.removeItem(at: link)
    try manager.removeItem(at: destination)
}
do {
    let file = try write()
    let link = root.appendingPathComponent("LinkedConnections")
    try manager.createSymbolicLink(at: link, withDestinationURL: directory)
    rejected(file.lastPathComponent, in: link, label: "connection directory symlink rejected")
    check(manager.fileExists(atPath: file.path), "directory symlink cannot consume target")
    try manager.removeItem(at: file)
}
do {
    let file = directory.appendingPathComponent("cmux-AbC123.json")
    guard mkfifo(file.path, 0o600) == 0 else { fatalError("fixture mkfifo failed") }
    rejected(file.lastPathComponent, label: "FIFO rejected without waiting for writer")
    try manager.removeItem(at: file)
    try manager.createDirectory(at: file, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    rejected(file.lastPathComponent, label: "directory cannot masquerade as request")
    try manager.removeItem(at: file)
}
do {
    let outside = try write(in: root)
    for name in ["../" + outside.lastPathComponent, outside.path, "cmux-AbC123.json/../cmux-AbC123.json", ".", "", "cmux-AbC123.json\0extra"] {
        rejected(name, label: "non-basename request rejected")
    }
    check(manager.fileExists(atPath: outside.path), "traversal leaves outside file untouched")
}
for name in ["cmux-AbC123.json\n", "cmux-AbC123.json\r", "cmux-AbC123.json\r\n", "cmux-12345.json", "cmux-1234567.json", "cmux-12345_.json", "cmux-AbC123.json.bak"] {
    let file = try write(name)
    rejected(name, label: "strict request basename required")
    check(manager.fileExists(atPath: file.path), "invalid basename file remains untouched")
    try? manager.removeItem(at: file)
}
rejected("cmux-AbC123.json", in: root.appendingPathComponent("MissingDirectory"), label: "missing directory rejected")
print("cmux connection requests: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
