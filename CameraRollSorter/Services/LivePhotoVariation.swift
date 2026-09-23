import Photos

/// The Live Photo "flavor" of an asset, for labeling and filtering.
///
/// Apple exposes no public API to distinguish Loop / Bounce / Long Exposure —
/// they all share `PHAssetMediaSubtype.photoLive`. We read the undocumented
/// `playbackVariation` KVC value as a best effort and fall back to the public
/// `playbackStyle` when it's unavailable. This is defensive: a missing or
/// renamed key never crashes and simply yields `.live` (or `.none`).
enum LivePhotoVariation: Sendable {
    case none          // not a Live Photo
    case live          // genuine Live Photo (motion + audio)
    case loop
    case bounce
    case longExposure

    /// A short badge label, or nil when there's nothing to badge.
    var badgeText: String? {
        switch self {
        case .none: return nil
        case .live: return String(localized: "LIVE", comment: "Live Photo badge")
        case .loop: return String(localized: "LOOP", comment: "Loop Live Photo badge")
        case .bounce: return String(localized: "BOUNCE", comment: "Bounce Live Photo badge")
        case .longExposure: return String(localized: "LONG EXPOSURE", comment: "Long Exposure Live Photo badge")
        }
    }



    /// True for the two kinds this app can convert to a plain still: a genuine
    /// Live Photo and a Long Exposure. Loop and Bounce are excluded.
    var isConvertibleToStill: Bool {
        self == .live || self == .longExposure
    }

    /// Classify an asset. Only assets flagged `.photoLive` can be anything other
    /// than `.none`.
    static func of(_ asset: PHAsset) -> LivePhotoVariation {
        guard asset.mediaSubtypes.contains(.photoLive) else { return .none }

        // Undocumented Photos value: 0 = None (plain Live), 1 = Loop,
        // 2 = Bounce, 3 = Long Exposure. `as? Int` yields nil if the value is
        // absent, in which case we fall back to the public playbackStyle.
        if let variation = asset.value(forKey: "playbackVariation") as? Int {
            switch variation {
            case 1: return .loop
            case 2: return .bounce
            case 3: return .longExposure
            case 0: return .live
            default: break
            }
        }

        // Public fallback: Loop/Bounce report .imageAnimated; Live and Long
        // Exposure report .livePhoto. Can't split Live vs Long Exposure here,
        // so both read as .live.
        switch asset.playbackStyle {
        case .livePhoto: return .live
        case .imageAnimated: return .loop   // loop or bounce; label generically
        default: return .live
        }
    }
}
