import Darwin
import Foundation
import Security
import LocalAuthentication

enum CmuxConnectionStore {
    enum Failure: Error {
        case invalidRequest, keychain
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Math Peek/Connections", isDirectory: true)
    private static let key: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.mathpeek.preview.cmux",
        kSecAttrAccount as String: "local-terminal"
    ]

    static func consume(_ name: String, in directory: URL = directory) throws -> CmuxSocket.Connection {
        guard name.range(of: "\\Acmux-[A-Za-z0-9]{6}\\.json\\z", options: .regularExpression) != nil else {
            throw Failure.invalidRequest
        }
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Failure.invalidRequest }
        defer { close(folder) }
        var metadata = stat()
        guard fstat(folder, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else { throw Failure.invalidRequest }
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.invalidRequest }
        defer { close(descriptor) }
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0,
              metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= 16384 else {
            throw Failure.invalidRequest
        }
        // Delete before parsing so a malformed or replayed URL cannot retain credentials.
        guard unlinkat(folder, name, 0) == 0 else { throw Failure.invalidRequest }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.invalidRequest }
            offset += count
        }
        guard let connection = try? JSONDecoder().decode(CmuxSocket.Connection.self, from: Data(bytes)) else {
            throw Failure.invalidRequest
        }
        try connection.validate()
        return connection
    }

    static func load() -> CmuxSocket.Connection? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authenticationContext()
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let connection = try? JSONDecoder().decode(CmuxSocket.Connection.self, from: data),
              (try? connection.validate()) != nil else { return nil }
        return connection
    }

    static func save(_ connection: CmuxSocket.Connection) throws {
        try connection.validate()
        let data = try JSONEncoder().encode(connection)
        var query = key
        query[kSecUseAuthenticationContext as String] = authenticationContext()
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.keychain }
        var item = key
        item[kSecValueData as String] = data
        item[kSecUseAuthenticationContext as String] = authenticationContext()
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.keychain }
    }

    static func remove() throws {
        var query = key
        query[kSecUseAuthenticationContext as String] = authenticationContext()
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw Failure.keychain }
    }

    private static func authenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
