import SwiftUI

/// The top-leading "LIVE" / "LOOP" / … capsule shown over a large photo.
/// Shared by `ZoomablePhotoView` (iOS) and `PhotoPreviewView` (macOS).
/// Renders nothing for non-Live photos.
struct LivePhotoBadge: View {
    let variation: LivePhotoVariation

    var body: some View {
        if let badge = variation.badgeText {
            HStack(spacing: 4) {
                variation.badgeIcon
                Text(badge)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.4), in: Capsule())
            .padding(10)
            .allowsHitTesting(false)
        }
    }
}

extension LivePhotoVariation {
    /// The badge's leading glyph, specific to each effect. Long Exposure uses
    /// the timer hand inside a dotted ring (matching the Photos long-exposure
    /// icon), which is composed from two symbols rather than a single one.
    @ViewBuilder
    var badgeIcon: some View {
        switch self {
        case .none, .live:
            Image(systemName: "livephoto")
        case .liveOff:
            Image(systemName: "livephoto.slash")   // Live turned off, like Photos
        case .loop:
            Image(systemName: "arrow.triangle.2.circlepath")   // continuous loop
        case .bounce:
            Image(systemName: "arrow.left.arrow.right")        // back-and-forth
        case .longExposure:
            // Timer hand centered in a dotted ring, like the Photos icon.
            ZStack {
                Image(systemName: "circle.dotted")
                Image(systemName: "timer")
                    .font(.system(size: 7, weight: .semibold))
            }
        }
    }
}
