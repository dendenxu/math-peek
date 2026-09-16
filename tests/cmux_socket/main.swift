import Darwin
import Foundation

var checks = 0
var failures = 0
func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL \(name)") }
}

final class MockServer {
    let path: String
    private let descriptor: Int32
    private let completed = DispatchGroup()
    private(set) var received = ""

    init(root: URL, response: @escaping ([String: Any]) -> Data, chunkSize: Int = 16_384, delay: TimeInterval = 0) throws {
        path = root.appendingPathComponent(UUID().uuidString + ".sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CmuxSocket.Failure.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strcpy($0, source) }
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw CmuxSocket.Failure.unavailable
        }
        completed.enter()
        DispatchQueue.global().async { [self] in
            defer { completed.leave() }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while data.count < 3 * 1024 * 1024 {
                let count = recv(client, &buffer, buffer.count, 0)
                guard count > 0 else { return }
                data.append(contentsOf: buffer.prefix(count))
                if data.contains(10) { break }
            }
            received = String(data: data, encoding: .utf8) ?? ""
            let fields = received.split(separator: " ", maxSplits: 2)
            guard fields.count == 3,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(fields[2].utf8)),
                  let object = parsed as? [String: Any] else { return }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let reply = response(object)
            var offset = 0
            while offset < reply.count {
                let count = reply.withUnsafeBytes {
                    send(client, $0.baseAddress!.advanced(by: offset), min(chunkSize, reply.count - offset), 0)
                }
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    func wait() { check(completed.wait(timeout: .now() + 2) == .success, "mock server completed") }
    deinit { close(descriptor); unlink(path) }
}

func encoded(_ object: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: object)
    data.append(10)
    return data
}
func success(_ request: [String: Any]) -> Data {
    encoded(["id": request["id"]!, "ok": true, "result": ["fixture": true]])
}
let manager = FileManager.default
let root = URL(fileURLWithPath: "/tmp/mp-cmux-" + UUID().uuidString.prefix(8))
try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? manager.removeItem(at: root) }
let fakeCapability = "fixture-secret.only-for-local-test"
func client(_ server: MockServer, pid: pid_t? = getpid()) -> CmuxSocket {
    CmuxSocket(connection: .init(socketPath: server.path, capability: fakeCapability), expectedPID: pid)
}
func expectFailure(_ expected: CmuxSocket.Failure, _ name: String, perform: () throws -> Void) {
    do { try perform(); check(false, name) }
    catch {
        check(error as? CmuxSocket.Failure == expected, name)
        check(!String(describing: error).contains("fixture-secret"), "failure does not disclose server payload or credentials")
    }
}

do {
    let server = try MockServer(root: root, response: success, chunkSize: 1)
    let result = try client(server).call(.paneList, params: ["window_id": "window-fixture"])
    check(result["fixture"] as? Bool == true, "fragmented response reconstructed")
    server.wait()
    check(server.received.hasPrefix("_cmux_capability_v1 " + fakeCapability + " "), "official capability wire envelope")
    check(server.received.hasSuffix("\n") && server.received.filter({ $0 == "\n" }).count == 1, "one line protocol")
    let fields = server.received.split(separator: " ", maxSplits: 2)
    let request = try JSONSerialization.jsonObject(with: Data(fields[2].utf8)) as! [String: Any]
    check(request["method"] as? String == "pane.list", "read-only method serialized")
    check((request["params"] as? [String: String])?["window_id"] == "window-fixture", "request params preserved")
}
for (name, expected, response) in [
    ("mismatched response id rejected", CmuxSocket.Failure.invalidResponse, { (_: [String: Any]) in encoded(["id": "other", "ok": true, "result": [:]]) }),
    ("non-boolean ok rejected", .invalidResponse, { (r: [String: Any]) in encoded(["id": r["id"]!, "ok": 1, "result": [:]]) }),
    ("error response rejected without payload disclosure", .rejected, { (r: [String: Any]) in encoded(["id": r["id"]!, "ok": false, "error": ["message": "fixture-secret"]]) }),
    ("non-object result rejected", .invalidResponse, { (r: [String: Any]) in encoded(["id": r["id"]!, "ok": true, "result": []]) }),
    ("malformed JSON rejected", .invalidResponse, { (_: [String: Any]) in Data("fixture-secret\n".utf8) }),
    ("premature EOF rejected", .invalidResponse, { (_: [String: Any]) in Data() }),
    ("oversized response rejected", .responseTooLarge, { (_: [String: Any]) in Data(repeating: 0x61, count: CmuxSocket.responseLimit + 1) })
] {
    let server = try MockServer(root: root, response: response)
    expectFailure(expected, name) { _ = try client(server).call(.systemCapabilities, timeout: 1) }
    server.wait()
}
do {
    let server = try MockServer(root: root, response: success, delay: 0.2)
    let started = DispatchTime.now().uptimeNanoseconds
    expectFailure(.timeout, "read respects total deadline") { _ = try client(server).call(.debugTerminals, timeout: 0.04) }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    check(elapsed < 0.15, "deadline does not wait for server response")
    server.wait()
}
do {
    let server = try MockServer(root: root, response: success)
    expectFailure(.unexpectedPeer, "unexpected server process rejected") { _ = try client(server, pid: getpid() + 100_000).call(.mobileHostStatus) }
    server.wait()
    check(server.received.isEmpty, "capability is not sent to unexpected process")
}
let unavailable = CmuxSocket(connection: .init(socketPath: root.appendingPathComponent("absent.sock").path, capability: fakeCapability))
expectFailure(.unavailable, "missing endpoint fails without hanging") { _ = try unavailable.call(.mobileTerminalReplay) }
for path in ["tcp://localhost:1234", "relative", "/tmp/with\0nul", "/" + String(repeating: "x", count: 103)] {
    let invalid = CmuxSocket(connection: .init(socketPath: path, capability: fakeCapability))
    expectFailure(.invalidConnection, "invalid local path rejected") { _ = try invalid.call(.paneList) }
}
for token in ["", "fixture-secret\ncommand", "fixture-secret\u{e9}", String(repeating: "x", count: 8193)] {
    let invalid = CmuxSocket(connection: .init(socketPath: "/tmp/absent.sock", capability: token))
    expectFailure(.invalidConnection, "invalid capability rejected") { _ = try invalid.call(.paneList) }
}
for timeout in [TimeInterval.nan, .infinity, -1, 0, 31] {
    expectFailure(.invalidRequest, "invalid deadline rejected") { _ = try unavailable.call(.paneList, timeout: timeout) }
}
expectFailure(.invalidRequest, "non-JSON params rejected before connecting") {
    _ = try unavailable.call(.paneList, params: ["invalid": Date()])
}
let connection = CmuxSocket.Connection(socketPath: "/tmp/cmux-fixture.sock", capability: fakeCapability)
let decoded = try JSONDecoder().decode(CmuxSocket.Connection.self, from: JSONEncoder().encode(connection))
check(decoded == connection && decoded.version == 1 && decoded.kind == "cmux", "connection storage schema round trip")
print("cmux socket: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
