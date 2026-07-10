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
    private(set) var apiKey: String
    private(set) var connectedIdentity: Identity?
    private(set) var availableModels: [ModelOption] = ModelOption.fallback

    var baseURL: URL = AppSettings.defaultBaseURL

    /// Last-picked model, persisted in UserDefaults.
    var defaultModelID: String {
        didSet { UserDefaults.standard.set(defaultModelID, forKey: "defaultModelID") }
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    func model(named id: String?) -> ModelOption? {
        availableModels.first { $0.modelID == id } ?? ModelOption.named(id)
    }

    /// Replaces the bootstrap catalog only after a complete server response.
    /// Until `/models/capabilities` ships, the current production 404 leaves
    /// the last-known-good/bootstrap catalog intact.
    func refreshModelCapabilities(using api: ConductorAPI) async {
        guard let response = try? await api.modelCapabilities(), !response.data.isEmpty else { return }
        availableModels = response.data.map(\.option)
        if !availableModels.contains(where: { $0.modelID == defaultModelID }) {
            defaultModelID = response.data.first(where: { $0.isDefault == true })?.id
                ?? response.data[0].id
        }
    }

    init() {
        self.apiKey = AppSettings.loadAPIKey() ?? ""
        // One-time migration: the app default changed to GPT-5.5 Medium.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didMigrateDefaultModelV2") {
            defaults.set(true, forKey: "didMigrateDefaultModelV2")
            defaults.removeObject(forKey: "defaultModelID")
        }
        // GPT-5.5 is no longer offered. Preserve any other explicit selection.
        if !defaults.bool(forKey: "didMigrateDefaultModelV3") {
            defaults.set(true, forKey: "didMigrateDefaultModelV3")
            if defaults.string(forKey: "defaultModelID") == "gpt-5.5" {
                defaults.removeObject(forKey: "defaultModelID")
            }
        }
        self.defaultModelID = defaults.string(forKey: "defaultModelID") ?? ModelOption.default.modelID
    }

    // MARK: - Keychain

    private static let keychainService = "build.conductor.conduit"
    private static let keychainAccount = "apiKey"

    /// Persists a key only after the caller has validated it with `/me`.
    func saveValidatedAPIKey(_ key: String, identity: Identity) throws {
        try Self.saveAPIKey(key)
        apiKey = key
        connectedIdentity = identity
    }

    func clearAPIKey() throws {
        try Self.saveAPIKey("")
        apiKey = ""
        connectedIdentity = nil
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func saveAPIKey(_ key: String) throws {
        var query = keychainQuery()
        // Empty key clears the stored value.
        guard let data = key.data(using: .utf8), !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
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

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Couldn't save the API key to Keychain: \(detail)"
    }
}
