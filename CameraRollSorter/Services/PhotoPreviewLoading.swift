import Photos

/// Async PhotoKit loads for the large single-photo views (`ZoomablePhotoView`
/// on iOS, `PhotoPreviewView` on macOS). Local-only (no network); each waits
/// for the final, non-degraded delivery and returns nil when cancelled or
/// unavailable.
enum PhotoPreviewLoading {
    /// The Live Photo flavor of the asset (drives the badge and playback).
    static func variation(for identifier: String) -> LivePhotoVariation {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return .none
        }
        return LivePhotoVariation.of(asset)
    }

    /// A 1024-pt aspect-fit preview.
    static func previewImage(for identifier: String) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier], options: nil
            ).firstObject else {
                continuation.resume(returning: nil)
                return
            }
            var resumed = false
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1024, height: 1024),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                guard !resumed else { return }
                if cancelled {
                    resumed = true
                    continuation.resume(returning: nil)
                } else if !degraded {
                    resumed = true
                    continuation.resume(returning: image)
                }
                // Ignore degraded previews; wait for the final delivery.
            }
        }
    }

    /// The Live Photo, for playback.
    static func livePhoto(for identifier: String) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier], options: nil
            ).firstObject else {
                continuation.resume(returning: nil)
                return
            }
            var resumed = false
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                guard !resumed else { return }
                if cancelled {
                    resumed = true
                    continuation.resume(returning: nil)
                } else if !degraded {
                    resumed = true
                    continuation.resume(returning: livePhoto)
                }
                // Ignore degraded deliveries; wait for the final one.
            }
        }
    }
}
