import Foundation

/// Persisted per-workspace "last real activity" ledger. Fed only by signals
/// that cannot lie: newest cached message timestamps and observed .working
/// statuses. Never fed by SessionStatus.updatedAt (a row-write timestamp that
/// bulk infra events stamp en masse).
nonisolated enum ActivityLedger {
    private static let key = "activityByWorkspace"

    static func activity(for workspaceID: String) -> Date? {
        guard let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let epoch = stored[workspaceID] else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Records activity, only ever moving the date forward.
    static func record(_ date: Date, for workspaceID: String) {
        var stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let epoch = date.timeIntervalSince1970
        if let existing = stored[workspaceID], existing >= epoch { return }
        stored[workspaceID] = epoch
        UserDefaults.standard.set(stored, forKey: key)
    }

    static func all() -> [String: Date] {
        let stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        return stored.mapValues { Date(timeIntervalSince1970: $0) }
    }
}
