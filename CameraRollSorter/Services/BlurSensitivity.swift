import Foundation

/// The user-facing "Low-aesthetic" sensitivity setting, expressed as a
/// continuous, user-tunable cutoff on Vision's overall image-aesthetics score.
/// Persisted in `UserDefaults` under a stable key, read by both the settings
/// screen (`@AppStorage`) and `BlurryPhotosModel`.
///
/// A photo is flagged as low-aesthetic when it is non-utility AND its overall
/// aesthetics score is strictly below the active cutoff (see
/// `isBlurry(variance:cutoff:)`, whose parameter is now the aesthetics score).
/// Vision's overall score is roughly in the range −1…1, where higher is a more
/// aesthetically pleasing photo. A higher cutoff is therefore MORE sensitive
/// (flags a superset of photos), a lower cutoff is less sensitive (a subset).
///
/// Because the decision is monotonic in the cutoff, `BlurryPhotosModel` applies
/// an asymmetric re-check when the cutoff changes: LOWERING the cutoff only
/// tightens the already-classified set, so it re-filters current results in
/// place by their stored score (no re-scan); RAISING the cutoff can admit
/// previously-passing photos whose scores were never retained, so it requires a
/// full re-scan. See `BlurryPhotosModel.applySensitivity()`.
///
/// The cutoff is intentionally kept independent of PhotoKit/Vision so the
/// decision can be exercised by pure property tests.
enum BlurSensitivity {
    /// Stable `UserDefaults` / `@AppStorage` key for the persisted setting.
    /// Reused across the metric change so existing installs migrate silently
    /// (a stale out-of-range value is clamped into the aesthetics range).
    static let storageKey = "blurry.sensitivity"

    /// Default cutoff used when nothing is stored yet. Set low so only clearly
    /// poor photos are flagged out of the box; the user can raise sensitivity.
    static let defaultCutoff: Double = -0.1

    /// Slider lower bound: the LEAST sensitive setting (flags the fewest photos).
    static let minCutoff: Double = -1.0

    /// Slider upper bound: the MOST sensitive setting (flags the most photos).
    static let maxCutoff: Double = 1.0

    /// The currently persisted cutoff. Uses `object(forKey:)` to distinguish a
    /// genuinely unset key (→ `defaultCutoff`) from a stored value, since —
    /// unlike the old variance metric — a valid aesthetics cutoff can be zero or
    /// negative. Any stored value is clamped into `[minCutoff, maxCutoff]`,
    /// which also migrates stale values left by the previous variance metric.
    static var currentCutoff: Double {
        guard let stored = UserDefaults.standard.object(forKey: storageKey) as? Double else {
            return defaultCutoff
        }
        return min(max(stored, minCutoff), maxCutoff)
    }

    /// Pure low-aesthetic decision: the photo's score is strictly below the
    /// cutoff. The parameter is named `variance` for source compatibility with
    /// the previous metric (and the pure property tests); it now carries the
    /// Vision aesthetics score. Usable independently of PhotoKit/Vision.
    nonisolated static func isBlurry(variance: Double, cutoff: Double) -> Bool {
        variance < cutoff
    }
}
