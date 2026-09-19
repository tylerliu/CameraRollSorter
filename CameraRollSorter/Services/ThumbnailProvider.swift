import Photos
import UIKit

/// Shared thumbnail cache + PhotoKit image manager for grid/list cells.
///
/// Why this exists: `LazyVGrid`/`List` already virtualize rows, so the scroll
/// slowdown isn't row count — it's per-cell work. Two costs were hit on every
/// cell appearance: a synchronous `PHAsset.fetchAssets(withLocalIdentifiers:)`
/// on the main thread, and a fresh decode with no reuse when scrolling back.
///
/// This provider fixes both with:
///  - a `PHCachingImageManager` (reuses decoded images across requests),
///  - an in-memory `NSCache` of finished thumbnails keyed by id + size + mode,
///  - a small `PHAsset` lookup cache so we don't re-fetch per appearance.
///
/// `@MainActor` because callers are SwiftUI views; the actual decode happens off
/// the main thread inside PhotoKit and the completion hops back to the main
/// actor.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()
    private var assetByID: [String: PHAsset] = [:]

    private init() {
        // Bound the cache so a huge library can't grow memory without limit.
        cache.countLimit = 400
    }

    private func cacheKey(_ id: String, size: CGFloat, fill: Bool) -> NSString {
        "\(id)|\(Int(size))|\(fill ? "fill" : "fit")" as NSString
    }

    /// A finished thumbnail already in memory, if any. Lets a cell show its
    /// image immediately on scroll-back with no spinner flash.
    func cachedImage(id: String, size: CGFloat, fill: Bool) -> UIImage? {
        cache.object(forKey: cacheKey(id, size: size, fill: fill))
    }

    /// Resolve a `PHAsset`, caching the lookup so repeated cell appearances
    /// don't each pay for a synchronous fetch.
    private func asset(for id: String) -> PHAsset? {
        if let cached = assetByID[id] { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return nil
        }
        assetByID[id] = asset
        return asset
    }

    /// Request a thumbnail. Delivers opportunistically (a fast low-res frame may
    /// arrive first, then the final). `completion` is called on the main actor;
    /// `isFinal` distinguishes the last delivery. Returns a request id the caller
    /// can cancel on disappear.
    @discardableResult
    func requestThumbnail(
        id: String,
        size: CGFloat,
        fill: Bool,
        completion: @escaping @MainActor (UIImage?, _ isFinal: Bool) -> Void
    ) -> PHImageRequestID? {
        if let cached = cachedImage(id: id, size: size, fill: fill) {
            completion(cached, true)
            return nil
        }
        guard let asset = asset(for: id) else {
            completion(nil, true)
            return nil
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        let dimension = max(1, size * 2) // points → pixels headroom
        let contentMode: PHImageContentMode = fill ? .aspectFill : .aspectFit
        let key = cacheKey(id, size: size, fill: fill)

        return manager.requestImage(
            for: asset,
            targetSize: CGSize(width: dimension, height: dimension),
            contentMode: contentMode,
            options: options
        ) { [weak self] image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            Task { @MainActor in
                guard !cancelled else { return }
                if let image, !degraded {
                    self?.cache.setObject(image, forKey: key)
                }
                completion(image, !degraded)
            }
        }
    }

    func cancel(_ requestID: PHImageRequestID?) {
        guard let requestID else { return }
        manager.cancelImageRequest(requestID)
    }
}
