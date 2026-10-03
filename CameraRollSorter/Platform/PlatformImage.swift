import SwiftUI

#if canImport(UIKit)
import UIKit
/// The image type PhotoKit delivers on this platform (`UIImage` on iOS).
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
/// The image type PhotoKit delivers on this platform (`NSImage` on macOS).
typealias PlatformImage = NSImage
#endif

extension Image {
    /// Cross-platform `Image(uiImage:)` / `Image(nsImage:)`.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// The backing bitmap, as-is (no orientation handling). Matches what the
    /// iOS aesthetics path has always passed to Vision (`UIImage.cgImage`).
    nonisolated var platformCGImage: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #else
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    /// A bitmap with the display orientation baked in, for feature prints.
    ///
    /// iOS: renders once through `UIGraphicsImageRenderer` (scale 1) — the exact
    /// normalization `SimilarityAnalyzer` used before, so feature-print distances
    /// and tuned thresholds are unchanged.
    /// macOS: PhotoKit's `NSImage` is already drawn upright, so its CGImage is used.
    nonisolated var orientationNormalizedCGImage: CGImage? {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return normalized.cgImage
        #else
        return platformCGImage
        #endif
    }
}
