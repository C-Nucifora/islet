import Foundation

enum DefaultsMigration {
  private static let originalBundleID = "dev.cnucifora.Islet"
  private static let migratedKey = "didMigrateFromCNuciforaBundle"

  /// The fork has its own bundle identity, but keeps every preference the user set under the
  /// original app. Current-domain values always win, so this is safe to leave in future releases.
  static func migrateFromOriginalBundleIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: migratedKey) else { return }
    if let legacy = defaults.persistentDomain(forName: originalBundleID) {
      for (key, value) in legacy where defaults.object(forKey: key) == nil {
        defaults.set(value, forKey: key)
      }
    }
    defaults.set(true, forKey: migratedKey)
  }
}
