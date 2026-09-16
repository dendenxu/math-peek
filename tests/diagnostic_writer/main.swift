import Foundation

var checks = 0
var failures = 0
func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL \(name)") }
}
func wait(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 3) == .success
}
func payload(_ value: String) -> Data { Data(value.utf8) }

let started = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let completed = DispatchSemaphore(value: 0)
let recorderLock = NSLock()
var received: [Data] = []
var allWritesOffMain = true
let destination = FileManager.default.temporaryDirectory
    .appendingPathComponent("math-peek-diagnostics-\(UUID().uuidString)")
    .appendingPathComponent("private/status.json")
let writer = DiagnosticWriter(url: destination) { data, _ in
    recorderLock.lock()
    received.append(data)
    allWritesOffMain = allWritesOffMain && !Thread.isMainThread
    recorderLock.unlock()
    if data == payload("first") {
        started.signal()
        _ = release.wait(timeout: .now() + 3)
    }
    if data == payload("latest") || data == payload("next") { completed.signal() }
}
writer.write(payload("first"))
check(wait(started), "background persistence starts")
for index in 0..<10_000 { writer.write(payload("superseded-\(index)")) }
writer.write(payload("latest"))
recorderLock.lock()
check(received == [payload("first")], "publishing does not wait for blocked disk persistence")
recorderLock.unlock()
release.signal()
check(wait(completed), "latest snapshot is eventually persisted")
recorderLock.lock()
check(received == [payload("first"), payload("latest")], "rapid updates retain only the newest pending snapshot")
check(allWritesOffMain, "all persistence runs off the main thread")
recorderLock.unlock()
writer.write(payload("next"))
check(wait(completed), "writer continues accepting snapshots after a drain")

enum ExpectedFailure: Error { case unavailable }
let failed = DispatchSemaphore(value: 0)
let recovered = DispatchSemaphore(value: 0)
let recoveringWriter = DiagnosticWriter(url: destination) { data, _ in
    if data == payload("fail") {
        failed.signal()
        throw ExpectedFailure.unavailable
    }
    recovered.signal()
}
recoveringWriter.write(payload("fail"))
check(wait(failed), "failed persistence attempt runs")
recoveringWriter.write(payload("recover"))
check(wait(recovered), "persistence errors do not stall later snapshots")

let fileWriter = DiagnosticWriter(url: destination)
let contents = payload("{\"stage\":\"ready\"}")
fileWriter.write(contents)
let deadline = Date().addingTimeInterval(3)
var fileIsPrivate = false
var directoryIsPrivate = false
var saved: Data?
repeat {
    saved = try? Data(contentsOf: destination)
    fileIsPrivate = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
    directoryIsPrivate = (try? FileManager.default.attributesOfItem(atPath: destination.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700
    if saved == contents && fileIsPrivate && directoryIsPrivate { break }
    Thread.sleep(forTimeInterval: 0.01)
} while Date() < deadline
check(saved == contents, "default persistence writes complete snapshot bytes")
check(fileIsPrivate, "diagnostic file is private (0600)")
check(directoryIsPrivate, "diagnostic directory is private (0700)")
try? FileManager.default.removeItem(at: destination.deletingLastPathComponent().deletingLastPathComponent())

print("Diagnostic writer: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
