import Foundation

final class DiagnosticWriter {
    private let url: URL
    private let persist: ((Data, URL) throws -> Void)?
    private let queue = DispatchQueue(label: "local.mathpeek.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending: Data?
    private var writing = false
    private var directoryPrepared = false

    init(url: URL, persist: ((Data, URL) throws -> Void)? = nil) {
        self.url = url
        self.persist = persist
    }

    func write(_ data: Data) {
        lock.lock()
        pending = data
        let start = !writing
        writing = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let data = pending else {
                writing = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            // Keep only the newest pending snapshot while an atomic write is in flight.
            if let persist { try? persist(data, url) }
            else { persistToFile(data) }
        }
    }

    private func persistToFile(_ data: Data) {
        do {
            if !directoryPrepared {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                directoryPrepared = true
            }
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            directoryPrepared = false
        }
    }
}
