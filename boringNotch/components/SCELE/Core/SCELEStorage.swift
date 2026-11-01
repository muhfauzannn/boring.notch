import Foundation
import LocalAuthentication
import Security

struct SCELECredentialStore {
    private let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "theboringteam.boringnotch") + ".scele") {
        self.service = service
    }

    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: "moodle_mobile_app", kSecUseAuthenticationContext as String: context]
    }

    func read() throws -> SCELECredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background refresh must never bring up an authentication dialog.
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SCELEError.keychain(status) }
        do { return try JSONDecoder().decode(SCELECredential.self, from: data) }
        catch { throw SCELEError.badResponse }
    }

    func save(_ credential: SCELECredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes = [kSecValueData as String: data] as [String: Any]
        let lookup = query
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SCELEError.keychain(added) }
        } else if status != errSecSuccess { throw SCELEError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SCELEError.keychain(status) }
    }
}

struct SCELECacheStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("tasks.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "theboringteam.boringnotch", isDirectory: true)
            .appendingPathComponent("SCELE", isDirectory: true)
    }

    func read(userID: Int) -> SCELECache? {
        guard let data = try? Data(contentsOf: file),
              let cache = try? JSONDecoder().decode(SCELECache.self, from: data), cache.userID == userID else { return nil }
        return cache
    }

    func save(_ cache: SCELECache) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(cache).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
