import Foundation

/// Persists a feature's scan-window controls (direction, "from date" toggle,
/// and the chosen date) across app launches. Each cleanup feature uses its own
/// `prefix`, so Similar photos, Live → Still, and Low-aesthetic each remember
/// their own window independently.
///
/// Backed by `UserDefaults`. Values are absolute: a date picked today is still
/// that same date on the next launch (it does not re-anchor to "today").
struct ScanWindowStore {
    let prefix: String

    private var directionKey: String { "\(prefix).scanDirection" }
    private var startEnabledKey: String { "\(prefix).scanStartEnabled" }
    private var startIntervalKey: String { "\(prefix).scanStartInterval" }

    // MARK: Direction

    /// Stored scan direction raw value ("older" / "newer"). Defaults to "newer"
    /// (Old→New) — the default scan order for every feature.
    var direction: String {
        get { UserDefaults.standard.string(forKey: directionKey) ?? "newer" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: directionKey) }
    }

    // MARK: "From date" toggle

    var startEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: startEnabledKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: startEnabledKey) }
    }

    // MARK: Start date (seconds since 1970; 0 = unset)

    var startInterval: Double {
        get { UserDefaults.standard.double(forKey: startIntervalKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: startIntervalKey) }
    }
}
