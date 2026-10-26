import Foundation
import Security

enum APIKeyStore {
    enum Source: String { case environment, repoEnvFile, keychain, missing }

    static let service = ProcessInfo.processInfo.environment["BEAN_KEYCHAIN_SERVICE"] ?? "dev.rayanbn.Bean.meta-api"
    private static let account = "MODEL_API_KEY"
    private static let lock = NSLock()
    private static var cached: String??

    static func current() -> (key: String?, source: Source) {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["MODEL_API_KEY"], !key.isEmpty { return (key, .environment) }
        if environment["BEAN_IGNORE_ENV_FILE"] == nil, let key = repoEnvFileKey() { return (key, .repoEnvFile) }
        if let key = keychainKey() { return (key, .keychain) }
        return (nil, .missing)
    }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
        lock.withLock { cached = .some(trimmed) }
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        lock.withLock { cached = .some(nil) }
    }

    private static func keychainKey() -> String? {
        if let cached = lock.withLock({ cached }) { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let key = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
            ? (result as? Data).map { String(decoding: $0, as: UTF8.self) } : nil
        lock.withLock { cached = .some(key) }
        return key
    }

    private static func repoEnvFileKey() -> String? {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "BeanSourceRoot") as? String,
              let text = try? String(contentsOfFile: root + "/.env", encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .first { $0.hasPrefix("MODEL_API_KEY=") }
            .map { $0.dropFirst("MODEL_API_KEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    enum KeyError: LocalizedError {
        case keychain(OSStatus)
        var errorDescription: String? {
            if case let .keychain(status) = self { return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
            return nil
        }
    }
}
