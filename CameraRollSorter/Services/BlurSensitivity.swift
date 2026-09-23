import Foundation

/// The user-facing blur sensitivity setting, expressed as a continuous,
/// user-tunable Laplacian-variance cutoff. Persisted in `UserDefaults` under a
/// stable key, read by both the settings screen (`@AppStorage`) and
/// `BlurryPhotosModel`.
///
/// A photo is classified blurry when its Laplacian variance is strictly below
/// the active cutoff (see `isBlurry(variance:cutoff:)`). The setting is now the
/// cutoff value itself rather than a Low/Medium/High enum: a higher cutoff is
/// MORE sensitive (flags a superset of photos), a lower cutoff is less
/// sensitive (flags a subset).
///
/// Because the decision is monotonic in the cutoff, `BlurryPhotosModel`
/// applies an asymmetric re-check when the cutoff changes: LOWERING the cutoff
/// only tightens the already-classified set, so it re-filters current results
/// in place by their stored variance (no re-scan); RAISING the cutoff can admit
/// previously-passing photos whose variances were never retained, so it
/// requires a full re-scan. See `BlurryPhotosModel.applySensitivity()`.
///
/// The cutoff is intentionally kept independent of PhotoKit so the decision can
/// be exercised by pure property tests.
enum BlurSensitivity {
    /// Stable `UserDefaults` / `@AppStorage` key for the persisted setting.
    static let storageKey = "blurry.sensitivity"

    /// Default cutoff used when nothing is stored yet. Matches the old
    /// `.medium` mapping so existing behavior is preserved.
    static let defaultCutoff: Double = 18.0

    /// Slider lower bound: the LEAST sensitive setting (flags the fewest photos).
    static let minCutoff: Double = 2.0

    /// Slider upper bound: the MOST sensitive setting (flags the most photos).
    static let maxCutoff: Double = 60.0

    /// The currently persisted cutoff. `UserDefaults.double(forKey:)` returns 0
    /// when the key is unset, so a stored value <= 0 (or absent) is treated as
    /// `defaultCutoff`; any stored value is otherwise clamped into
    /// `[minCutoff, maxCutoff]`.
    static var currentCutoff: Double {
        let stored = UserDefaults.standard.double(forKey: storageKey)
        guard stored > 0 else { return defaultCutoff }
        return min(max(stored, minCutoff), maxCutoff)
    }

    /// Pure blur decision: a photo is blurry exactly when its Laplacian
    /// variance is strictly below the cutoff. Usable independently of PhotoKit.
    nonisolated static func isBlurry(variance: Double, cutoff: Double) -> Bool {
        variance < cutoff
    }
}
