import Photos
import UIKit

/// Shared PhotoKit helpers used by the background analysis actors
/// (`SimilarityAnalyzer`, `AestheticsScorer`). Kept nonisolated and synchronous
/// because both callers run inside their own actor + `autoreleasepool` and want
/// a blocking, local-only fetch.
nonisolated enum PhotoImageLoading {
    /// Synchronously loads a local, non-degraded still for `identifier` at the
    /// given square target size. Returns nil if the asset is missing or the
    /// image isn't available locally.
    ///
    /// This is the exact request configuration both analysis actors relied on:
    /// synchronous, no network, high quality, exact resize.
    static func synchronousImage(for identifier: String, targetSize: CGFloat) -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current

        var loaded: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: targetSize, height: targetSize),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            guard (info?[PHImageResultIsDegradedKey] as? Bool) != true,
                  info?[PHImageErrorKey] == nil,
                  (info?[PHImageCancelledKey] as? Bool) != true else { return }
            loaded = image
        }
        return loaded
    }
}
