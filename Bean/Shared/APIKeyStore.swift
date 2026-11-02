import Foundation
import Security

enum APIKeyStore {
    enum Source: String { case environment, repoEnvFile, keychain, missing }

    private static let account = "MODEL_API_KEY"
    private static let lock = NSLock()
    private static var cache: [AIProvider: String?] = [:]

    static func current(for provider: AIProvider = BeanSettings.shared.effectiveProvider) -> (key: String?, source: Source) {
        guard provider != .local else { return (nil, .missing) }
        let environment = ProcessInfo.processInfo.environment
        if let key = environment[variable(for: provider)], !key.isEmpty { return (key, .environment) }
        if environment["BEAN_IGNORE_ENV_FILE"] == nil, let key = repoEnvFileKey(variable(for: provider)) { return (key, .repoEnvFile) }
        if let key = keychainKey(for: provider) { return (key, .keychain) }
        return (nil, .missing)
    }

    static func save(_ key: String, for provider: AIProvider = BeanSettings.shared.provider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = baseQuery(for: provider)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
        lock.withLock { cache[provider] = .some(trimmed) }
    }

    static func delete(for provider: AIProvider = BeanSettings.shared.provider) {
        SecItemDelete(baseQuery(for: provider) as CFDictionary)
        lock.withLock { cache[provider] = .some(nil) }
    }

    static func service(for provider: AIProvider) -> String {
        let base = ProcessInfo.processInfo.environment["BEAN_KEYCHAIN_SERVICE"] ?? "dev.rayanbn.Bean"
        return provider == .meta ? "\(base).meta-api" : "\(base).\(provider.rawValue)"
    }

    static func named(_ variable: String) -> String? {
        if let key = ProcessInfo.processInfo.environment[variable], !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment["BEAN_IGNORE_ENV_FILE"] == nil ? repoEnvFileKey(variable) : nil
    }

    private static func variable(for provider: AIProvider) -> String {
        switch provider {
        case .meta: return "MODEL_API_KEY"
        case .openRouter: return "OPENROUTER_API_KEY"
        case .openAICompatible: return "OPENAI_API_KEY"
        case .local: return "LOCAL_API_KEY"
        }
    }

    private static func baseQuery(for provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(for: provider), kSecAttrAccount as String: account]
    }

    private static func keychainKey(for provider: AIProvider) -> String? {
        if let cached = lock.withLock({ cache[provider] }) { return cached }
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let key = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
            ? (result as? Data).map { String(decoding: $0, as: UTF8.self) } : nil
        lock.withLock { cache[provider] = .some(key) }
        return key
    }

    private static func repoEnvFileKey(_ variable: String) -> String? {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "BeanSourceRoot") as? String,
              let text = try? String(contentsOfFile: root + "/.env", encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .first { $0.hasPrefix(variable + "=") }
            .map { $0.dropFirst(variable.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
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
