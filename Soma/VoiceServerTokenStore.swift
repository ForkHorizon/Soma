import Foundation
import Security

enum VoiceServerTokenStore {
    private static let service = "Daliys.Soma.VoiceServer"
    private static let account = "default"
    private static let legacyDefaultsKey = "voiceServerToken"

    static func load() -> String {
        if let token = loadKeychainWithoutPrompt(), !token.isEmpty {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return token
        }
        guard let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !legacy.isEmpty
        else {
            return ""
        }
        saveKeychainWithoutPrompt(legacy)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        return legacy
    }

    @discardableResult
    static func save(_ token: String) -> String? {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            deleteKeychainWithoutPrompt()
            return nil
        }
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        saveKeychainWithoutPrompt(clean)
        return nil
    }

    private static func loadKeychainWithoutPrompt() -> String? {
        var query = baseQuery(skipAuthUI: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let token = String(data: data, encoding: .utf8)
        else { return "" }
        return token
    }

    private static func saveKeychainWithoutPrompt(_ clean: String) {
        let data = Data(clean.utf8)
        let query = baseQuery(skipAuthUI: true)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = baseQuery(skipAuthUI: false)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func deleteKeychainWithoutPrompt() {
        _ = SecItemDelete(baseQuery(skipAuthUI: true) as CFDictionary)
    }

    private static func baseQuery(skipAuthUI: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if skipAuthUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        return query
    }
}
