#if os(macOS)
import Photos

/// File URLs for PhotoKit assets, for APIs that only take files (Quick Look).
enum PhotoFileURL {
    /// The URL of the asset's current full-size image (edits applied), as
    /// already stored by Photos — nothing is copied. Local only: nil if the
    /// image isn't on this Mac (no iCloud download) or the asset is gone.
    static func fullSizeImage(for identifier: String) async -> URL? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input?.fullSizeImageURL)
            }
        }
    }
}
#endif
