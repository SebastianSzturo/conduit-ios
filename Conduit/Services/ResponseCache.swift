import Foundation

/// Small file-backed JSON cache for API responses (stale-while-revalidate).
///
/// Files live in Caches/ConduitCache/ — the system may purge them at any time,
/// which is fine: everything cached here is re-fetchable from the network.
/// Payloads are wrapped in a versioned envelope; decode failures or version
/// mismatches delete the file and return nil.
nonisolated enum ResponseCache {
    /// Bump when any cached payload's shape changes incompatibly.
    static let schemaVersion = 1

    private struct Envelope<Payload: Codable>: Codable {
        let version: Int
        let payload: Payload
    }

    /// Serial queue for background writes; reads are synchronous (payloads are
    /// small-to-medium and reads happen once per screen appearance).
    private static let writeQueue = DispatchQueue(label: "conduit.response-cache", qos: .utility)

    private static var directory: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConduitCache", isDirectory: true)
    }

    private static func fileURL(for key: String) -> URL {
        // Sanitize the key into a safe filename.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return directory.appendingPathComponent(safe + ".json")
    }

    static func load<T: Decodable & Encodable>(_ type: T.Type, key: String) -> T? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data),
              envelope.version == schemaVersion else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return envelope.payload
    }

    static func save<T: Encodable & Decodable>(_ value: T, key: String) {
        let envelope = Envelope(version: schemaVersion, payload: value)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let url = fileURL(for: key)
        writeQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func remove(key: String) {
        let url = fileURL(for: key)
        writeQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func removeAll() {
        let dir = directory
        writeQueue.async {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
