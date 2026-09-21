import Foundation

/// The user-facing blur sensitivity setting and its mapping to a Laplacian-
/// variance cutoff. Persisted in `UserDefaults` under a stable key, read by
/// both the settings screen (`@AppStorage`) and `BlurryPhotosModel`.
///
/// A photo is classified blurry when its Laplacian variance is strictly below
/// the active cutoff (see `isBlurry(variance:cutoff:)`). The cutoff is
/// intentionally kept independent of PhotoKit so the decision can be exercised
/// by pure property tests.
enum BlurSensitivity: String, CaseIterable, Sendable {
    case low, medium, high

    /// Laplacian-variance cutoff. A photo is blurry when its variance < cutoff.
    ///
    /// MUST be monotonic non-decreasing across low → medium → high so a higher
    /// sensitivity flags a superset of what a lower one flags (Property 10).
    /// The ordering — not the exact numbers — is what the monotonicity property
    /// depends on; the constants are tuned against sample photos.
    var varianceCutoff: Double {
        switch self {
        case .low:    return 8.0
        case .medium: return 18.0
        case .high:   return 35.0
        }
    }

    /// Stable `UserDefaults` / `@AppStorage` key for the persisted setting.
    static let storageKey = "blurry.sensitivity"

    /// The currently persisted sensitivity, defaulting to `.medium` when unset
    /// or when the stored value is not a recognized case.
    static var current: BlurSensitivity {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(BlurSensitivity.init) ?? .medium
    }

    /// Pure blur decision: a photo is blurry exactly when its Laplacian
    /// variance is strictly below the cutoff. Usable independently of PhotoKit.
    nonisolated static func isBlurry(variance: Double, cutoff: Double) -> Bool {
        variance < cutoff
    }
}
