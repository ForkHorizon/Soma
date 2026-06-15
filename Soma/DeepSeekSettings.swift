import Foundation
import Security

enum DeepSeekCredentialStore {
    private static let service = "Daliys.Soma.DeepSeek"
    private static let account = "api-key"

    static func apply(to environment: inout [String: String]) {
        if hasEnvironmentAPIKey(environment) { return }
        guard let apiKey = keychainAPIKey(), !apiKey.isEmpty else { return }
        environment["SOMA_DEEPSEEK_API_KEY"] = apiKey
    }

    static func hasEnvironmentAPIKey(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let somaKey = environment["SOMA_DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plainKey = environment["DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(somaKey?.isEmpty ?? true) || !(plainKey?.isEmpty ?? true)
    }

    static func hasKeychainAPIKey() -> Bool {
        keychainAPIKey() != nil
    }

    static func keychainAPIKey() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func saveAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clearAPIKey()
            return
        }
        let data = Data(trimmed.utf8)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw DeepSeekCredentialError.securityStatus(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw DeepSeekCredentialError.securityStatus(status) }
    }

    static func clearAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekCredentialError.securityStatus(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var readQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}

enum DeepSeekCredentialError: LocalizedError {
    case securityStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .securityStatus(let status):
            return "Keychain error \(status)."
        }
    }
}
