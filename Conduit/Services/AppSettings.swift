import Foundation
import Observation
import Security

/// App-level configuration: API key (Keychain-backed), base URL, default model.
///
/// CONTRACT SKELETON — public surface fixed; foundation agent implements
/// Keychain persistence.
@Observable
final class AppSettings {
    static let defaultBaseURL = URL(string: "https://api.conductor.build/v0")!
    var apiKey: String {
        didSet { persistAPIKey() }
    }

    var baseURL: URL = AppSettings.defaultBaseURL

    /// Last-picked model, persisted in UserDefaults.
    var defaultModelID: String {
        didSet { UserDefaults.standard.set(defaultModelID, forKey: "defaultModelID") }
    }

    /// Last-picked thinking level, persisted in UserDefaults. Local-only for
    /// now: the v0 API does not accept a thinking level yet.
    var defaultThinkingLevel: ThinkingLevel {
        didSet { UserDefaults.standard.set(defaultThinkingLevel.rawValue, forKey: "defaultThinkingLevel") }
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    init() {
        self.apiKey = AppSettings.loadAPIKey() ?? ""
        // One-time migration: the app default changed to GPT-5.5 Medium.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didMigrateDefaultModelV2") {
            defaults.set(true, forKey: "didMigrateDefaultModelV2")
            defaults.removeObject(forKey: "defaultModelID")
        }
        self.defaultModelID = defaults.string(forKey: "defaultModelID") ?? ModelOption.default.modelID
        self.defaultThinkingLevel = defaults.string(forKey: "defaultThinkingLevel")
            .flatMap(ThinkingLevel.init(rawValue:)) ?? .default
    }

    // MARK: - Keychain

    private static let keychainService = "build.conductor.conduit"
    private static let keychainAccount = "apiKey"

    private func persistAPIKey() {
        Self.saveAPIKey(apiKey)
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func saveAPIKey(_ key: String) {
        var query = keychainQuery()
        // Empty key clears the stored value.
        guard let data = key.data(using: .utf8), !key.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func loadAPIKey() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }
}
