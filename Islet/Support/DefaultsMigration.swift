import Foundation

enum DefaultsMigration {
  private static let currentBundleID = "dev.cnucifora.Islet"
  private static let forkBundleID = "dev.nedlane.Islet"
  private static let migratedKey = "didMigrateFromNedlaneBundle"

  /// Import preferences created by the feature fork while keeping the upstream bundle identity.
  /// Current-domain values always win, so this is safe to leave in future releases.
  static func migrateFromFeatureForkIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: migratedKey) else { return }
    let existing = defaults.persistentDomain(forName: currentBundleID) ?? [:]
    if let legacy = defaults.persistentDomain(forName: forkBundleID) {
      for (key, value) in legacy where existing[key] == nil {
        defaults.set(value, forKey: key)
      }
    }
    defaults.set(true, forKey: migratedKey)
  }
}
