import Foundation
import Observation
import Photos

enum LiveToStillError: LocalizedError {
    case writeAccessRequired
    case stillDataUnavailable
    case changeRejected

    var errorDescription: String? {
        switch self {
        case .writeAccessRequired:
            return String(localized: "Photo access does not allow changes. Grant full or limited read-write access and try again.")
        case .stillDataUnavailable:
            return String(localized: "Couldn’t read the still image for this Live Photo locally.")
        case .changeRejected:
            return String(localized: "Photos did not accept the change request.")
        }
    }
}

/// A Live Photo eligible for conversion to a plain still. Only genuine Live
/// Photos and Long Exposure are included — never Loop or Bounce, which are
/// self-animating effects (PHAssetPlaybackStyle == .imageAnimated).
struct LivePhotoItem: Identifiable, Sendable {
    let id: String          // PHAsset.localIdentifier
    let date: Date
}

extension LivePhotoItem: ScanItem {}

/// Per-screen scan model for Live → Still. The shared incremental scan lives in
/// `IncrementalScanModel`; this adds Live Photo classification and conversion.
final class LiveToStillModel: IncrementalScanModel<LivePhotoItem> {
    @ObservationIgnored private let scanner = LivePhotoScanner()

    init() {
        super.init(windowPrefix: "liveToStill", batchSize: 200)
    }

    override func fetchCandidates() async -> [TimedPhoto] {
        await scanner.fetchCandidates()
    }

    override func classify(_ batch: [TimedPhoto]) async -> [LivePhotoItem] {
        await scanner.convertibleItems(in: batch.map(\.id))
    }

    /// Convert a set of Live Photos to stills.
    ///
    /// Done in two phases so the whole batch needs only ONE system deletion
    /// confirmation:
    /// 1. Read every still resource first (reads don't prompt).
    /// 2. In a single `performChanges` block, create all new stills and delete
    ///    all originals at once — PhotoKit shows one confirmation for the batch.
    ///
    /// Returns the number converted.
    @discardableResult
    func convertToStill(_ identifiers: Set<String>) async throws -> Int {
        guard canRead else {
            throw LiveToStillError.writeAccessRequired
        }

        // Phase 1 — gather (asset, still data). Reads only; no prompts.
        var jobs: [(asset: PHAsset, data: Data, originalFilename: String)] = []
        for id in identifiers {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { continue }
            let still = try await stillImageData(for: asset)
            jobs.append((asset, still.data, still.originalFilename))
        }
        guard !jobs.isEmpty else { return 0 }

        // Phase 2 — one atomic change: create all stills, delete all originals.
        try await replaceWithStills(jobs)

        // Drop converted originals from the visible list.
        let convertedIDs = Set(jobs.map { $0.asset.localIdentifier })
        removeFromCurrentResults(convertedIDs)
        return jobs.count
    }

    /// Delete the original Live Photo without converting it. PhotoKit supplies
    /// the system confirmation and leaves the library unchanged on cancellation.
    func deletePhoto(_ identifier: String) async throws {
        try await deletePhotos([identifier])
    }

    func deletePhotos(_ identifiers: Set<String>) async throws {
        guard canRead else { throw LiveToStillError.writeAccessRequired }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        guard assets.count > 0 else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LiveToStillError.changeRejected)
                }
            }
        }
        removeFromCurrentResults(identifiers)
    }

    /// Full-resolution still-image data for the Live Photo's photo resource.
    /// This data already carries the original EXIF/GPS metadata, so re-saving it
    /// verbatim preserves metadata without re-encoding.
    private func stillImageData(for asset: PHAsset) async throws -> (data: Data, originalFilename: String) {
        let resources = PHAssetResource.assetResources(for: asset)
        // The still component of a Live Photo is the .photo (or .fullSizePhoto) resource.
        let photoResource = resources.first { $0.type == .fullSizePhoto }
            ?? resources.first { $0.type == .photo }
        guard let resource = photoResource else {
            throw LiveToStillError.stillDataUnavailable
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { buffer.append($0) },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if buffer.isEmpty {
                        continuation.resume(throwing: LiveToStillError.stillDataUnavailable)
                    } else {
                        continuation.resume(returning: (buffer, resource.originalFilename))
                    }
                }
            )
        }
    }

    /// Create new still assets from the gathered data and delete all the Live
    /// originals — in a SINGLE change block. Batching the deletions into one
    /// `deleteAssets` call means the system shows just one confirmation for the
    /// whole conversion, not one per photo.
    private func replaceWithStills(_ jobs: [(asset: PHAsset, data: Data, originalFilename: String)]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                for job in jobs {
                    let creation = PHAssetCreationRequest.forAsset()
                    let resourceOptions = PHAssetResourceCreationOptions()
                    resourceOptions.originalFilename = job.originalFilename
                    // Pass the still data verbatim (no UIImage round-trip) so
                    // EXIF and GPS metadata survive intact.
                    creation.addResource(with: .photo, data: job.data, options: resourceOptions)
                    // Preserve capture date, location, and favorite status.
                    creation.creationDate = job.asset.creationDate
                    creation.location = job.asset.location
                    creation.isFavorite = job.asset.isFavorite
                }
                // One batched deletion for the whole set → one confirmation.
                let originals = jobs.map { $0.asset } as NSArray
                PHAssetChangeRequest.deleteAssets(originals)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LiveToStillError.changeRejected)
                }
            }
        }
    }
}

/// Background actor that finds convertible Live Photos: genuine Live, Long
/// Exposure, and Live Photos with Live turned off in the editor. Excludes Loop
/// and Bounce (playbackStyle == .imageAnimated).
private actor LivePhotoScanner {
    /// Fast metadata-only fetch of every image candidate (id + date). No
    /// per-asset classification here, so it returns quickly even for a large
    /// library. Classification happens later, in batches, via `convertibleItems`.
    func fetchCandidates() -> [TimedPhoto] {
        // Fetch EVERY image. A Live Photo whose Live was turned off in the
        // editor loses its `.photoLive` subtype, so a subtype predicate misses
        // it. The paired video resource survives, though, so classification
        // detects it by resource. (No `hasAdjustments` fetch predicate — that
        // key is unsupported and throws.)
        let assets = PHAsset.fetchAssets(with: .image, options: nil)
        var result: [TimedPhoto] = []
        var seen = Set<String>()
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            // Dedup by localIdentifier so a candidate id can never appear twice
            // downstream (which would make the grid's ForEach ids non-unique).
            guard seen.insert(asset.localIdentifier).inserted else { return }
            result.append(TimedPhoto(id: asset.localIdentifier, date: date))
        }
        return result
    }

    /// Classify a batch of candidate ids, returning only those convertible to a
    /// plain still (genuine Live, Long Exposure, and Live-off — never
    /// Loop/Bounce).
    func convertibleItems(in ids: [String]) -> [LivePhotoItem] {
        guard !ids.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var items: [LivePhotoItem] = []
        assets.enumerateObjects { asset, _, _ in
            guard LivePhotoVariation.of(asset).isConvertibleToStill else { return }
            guard let date = asset.creationDate else { return }
            items.append(LivePhotoItem(id: asset.localIdentifier, date: date))
        }
        return items
    }
}
