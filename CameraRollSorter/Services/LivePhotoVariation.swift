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
    case liveOff       // Live Photo whose Live was turned off in the editor:
                       // still a .photoLive asset, but playbackStyle == .image
    case loop
    case bounce
    case longExposure

    /// A short badge label, or nil when there's nothing to badge.
    var badgeText: String? {
        switch self {
        case .none: return nil
        case .live: return String(localized: "LIVE", comment: "Live Photo badge")
        case .liveOff: return String(localized: "LIVE OFF", comment: "Badge for a Live Photo whose Live is turned off")
        case .loop: return String(localized: "LOOP", comment: "Loop Live Photo badge")
        case .bounce: return String(localized: "BOUNCE", comment: "Bounce Live Photo badge")
        case .longExposure: return String(localized: "LONG EXPOSURE", comment: "Long Exposure Live Photo badge")
        }
    }

    /// True when the asset plays as a Live Photo (so the detail view should
    /// offer press-and-hold playback). A Live-off asset has playback suppressed,
    /// so it's excluded.
    var hasPlayableMotion: Bool {
        self == .live || self == .longExposure
    }

    /// True for the kinds this app can convert to a plain still: a genuine Live
    /// Photo, a Long Exposure, and a Live Photo with Live already turned off.
    /// Loop and Bounce are excluded.
    var isConvertibleToStill: Bool {
        self == .live || self == .longExposure || self == .liveOff
    }

    /// Classify an asset.
    ///
    /// A genuine Live Photo (playing) carries the `.photoLive` media subtype and
    /// is classified by its `playbackVariation` / `playbackStyle`.
    ///
    /// A Live Photo whose Live was turned off in the editor is trickier: Photos
    /// strips the `.photoLive` subtype AND resets `playbackStyle` to `.image`,
    /// so it's indistinguishable from a plain still by metadata alone. The one
    /// surviving signal is the paired video resource (`.pairedVideo` /
    /// `.fullSizePairedVideo`) — a plain still never has one. We use that to
    /// recognize `.liveOff`. (Verified on-device: a Live-off photo reports
    /// resourceTypes [.photo, .pairedVideo] with no `.photoLive` subtype and
    /// `hasAdjustments == false`.)
    static func of(_ asset: PHAsset) -> LivePhotoVariation {
        guard asset.mediaSubtypes.contains(.photoLive) else {
            // No subtype: either a plain still, or a Live Photo with Live turned
            // off. The paired video resource is the only thing that tells them
            // apart.
            return hasPairedVideoResource(asset) ? .liveOff : .none
        }

        // Undocumented Photos value: 0 = None (plain Live), 1 = Loop,
        // 2 = Bounce, 3 = Long Exposure. `as? Int` yields nil if the value is
        // absent, in which case we fall back to the public playbackStyle.
        if let variation = asset.value(forKey: "playbackVariation") as? Int {
            switch variation {
            case 1: return .loop
            case 2: return .bounce
            case 3: return .longExposure
            case 0: break          // plain Live — fall through to playbackStyle
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

    /// True when the asset carries a Live Photo's paired video resource. This is
    /// the only reliable signal for a Live Photo whose Live was turned off in
    /// the editor: it loses the `.photoLive` subtype and reports
    /// `playbackStyle == .image`, but the paired video stays attached.
    private static func hasPairedVideoResource(_ asset: PHAsset) -> Bool {
        guard asset.mediaType == .image else { return false }
        return PHAssetResource.assetResources(for: asset).contains {
            $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
        }
    }
}
