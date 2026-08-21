import Foundation

// ponytail: same 0600-file approach as DeepSeekCredentialStore (see that file for why not Keychain).
// Holds the Gemini *API* key (AI Studio) used by the REST provider — separate from the deprecated
// gemini CLI / AI Pro login.
enum GeminiCredentialStore {
    private static let store = FileAPIKeyStore(
        filename: "gemini-api-key", envKeys: ["SOMA_GEMINI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY"],
        exportEnvKey: "SOMA_GEMINI_API_KEY")

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
