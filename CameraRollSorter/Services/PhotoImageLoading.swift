import Photos
import Synchronization

/// Shared PhotoKit helpers used by the background analysis actors
/// (`SimilarityAnalyzer`, `AestheticsScorer`). PhotoKit loads asynchronously so
/// analysis tasks suspend instead of blocking on PhotoKit's lower-QoS workers.
nonisolated enum PhotoImageLoading {
    /// Loads a local, non-degraded still for `identifier` at the
    /// given square target size. Returns nil if the asset is missing or the
    /// image isn't available locally.
    ///
    static func image(for identifier: String, targetSize: CGFloat) async -> PlatformImage? {
        guard !Task.isCancelled else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current

        return await withCheckedContinuation { continuation in
            let finished = Mutex(false)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: targetSize, height: targetSize),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let failed = info?[PHImageErrorKey] != nil
                    || (info?[PHImageCancelledKey] as? Bool) == true
                guard failed || (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                let shouldResume = finished.withLock { value in
                    guard !value else { return false }
                    value = true
                    return true
                }
                if shouldResume { continuation.resume(returning: failed ? nil : image) }
            }
        }
    }
}
