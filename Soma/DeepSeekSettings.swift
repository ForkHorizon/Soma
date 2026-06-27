import Foundation

// ponytail: 0600 file, not Keychain. The app is ad-hoc signed (signature changes every rebuild),
// so the Keychain re-prompts and scopes items to a per-build identity a later build can't read.
// A file in Application Support is signature-independent — the same way CLIs keep their own API
// keys (~/.aws/credentials, .env). Method names kept (keychain*) so call sites don't churn.
enum DeepSeekCredentialStore {
    private static let store = FileAPIKeyStore(filename: "deepseek-api-key", envKeys: ["SOMA_DEEPSEEK_API_KEY", "DEEPSEEK_API_KEY"], exportEnvKey: "SOMA_DEEPSEEK_API_KEY")

    static func apply(to environment: inout [String: String]) {
        store.apply(to: &environment)
    }

    static func hasEnvironmentAPIKey(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        store.hasEnvironmentAPIKey(environment)
    }

    static func hasKeychainAPIKey() -> Bool {
        store.apiKey() != nil
    }

    static func keychainAPIKey() -> String? {
        store.apiKey()
    }

    static func saveAPIKey(_ apiKey: String) throws {
        try store.save(apiKey)
    }

    static func clearAPIKey() throws {
        try store.clear()
    }
}

struct FileAPIKeyStore {
    let filename: String
    let envKeys: [String]
    let exportEnvKey: String

    private var keyFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soma", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    func apply(to environment: inout [String: String]) {
        if hasEnvironmentAPIKey(environment) { return }
        guard let apiKey = apiKey() else { return }
        environment[exportEnvKey] = apiKey
    }

    func hasEnvironmentAPIKey(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        envKeys.contains { !(environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }

    func apiKey() -> String? {
        guard let raw = try? String(contentsOf: keyFileURL, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func save(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clear()
            return
        }
        let url = keyFileURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try trimmed.write(to: url, atomically: true, encoding: .utf8)
        // ponytail: atomic write briefly lands at umask perms before this chmod — fine for a
        // single-user machine; tighten to a pre-created 0600 fd if this ever ships multi-user.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear() throws {
        let url = keyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
