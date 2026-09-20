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
            return "Photo access does not allow changes. Grant full or limited read-write access and try again."
        case .stillDataUnavailable:
            return "Couldn’t read the still image for this Live Photo locally."
        case .changeRejected:
            return "Photos did not accept the change request."
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

@MainActor @Observable
final class LiveToStillModel {
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var items: [LivePhotoItem] = []
    var isScanning = false
    var hasScanned = false
    var errorMessage: String?
    // Remembers the top-visible grid item so scroll position is restored when
    // navigating away and back within a session. Not persisted across launches.
    var scrollAnchorID: String?

    private let scanner = LivePhotoScanner()
    private var scanTask: Task<Void, Never>?

    var canRead: Bool { authorization == .authorized || authorization == .limited }

    /// Scan the library for convertible Live Photos. Cheap metadata-only pass;
    /// runs on its own actor so it never blocks similarity analysis.
    func scan() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else {
            items = []
            hasScanned = false
            return
        }
        scanTask?.cancel()
        errorMessage = nil
        isScanning = true
        scanTask = Task {
            let found = await scanner.scan()
            guard !Task.isCancelled else { return }
            items = found
            scrollAnchorID = nil   // fresh results start at the top
            isScanning = false
            hasScanned = true
        }
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
        guard authorization == .authorized || authorization == .limited else {
            throw LiveToStillError.writeAccessRequired
        }

        // Phase 1 — gather (asset, still data). Reads only; no prompts.
        var jobs: [(asset: PHAsset, data: Data)] = []
        for id in identifiers {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { continue }
            let data = try await stillImageData(for: asset)
            jobs.append((asset, data))
        }
        guard !jobs.isEmpty else { return 0 }

        // Phase 2 — one atomic change: create all stills, delete all originals.
        try await replaceWithStills(jobs)

        // Drop converted originals from the visible list.
        let convertedIDs = Set(jobs.map { $0.asset.localIdentifier })
        items.removeAll { convertedIDs.contains($0.id) }
        return jobs.count
    }

    /// Full-resolution still-image data for the Live Photo's photo resource.
    /// This data already carries the original EXIF/GPS metadata, so re-saving it
    /// verbatim preserves metadata without re-encoding.
    private func stillImageData(for asset: PHAsset) async throws -> Data {
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
                        continuation.resume(returning: buffer)
                    }
                }
            )
        }
    }

    /// Create new still assets from the gathered data and delete all the Live
    /// originals — in a SINGLE change block. Batching the deletions into one
    /// `deleteAssets` call means the system shows just one confirmation for the
    /// whole conversion, not one per photo.
    private func replaceWithStills(_ jobs: [(asset: PHAsset, data: Data)]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                for job in jobs {
                    let creation = PHAssetCreationRequest.forAsset()
                    let resourceOptions = PHAssetResourceCreationOptions()
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

/// Background actor that finds convertible Live Photos. Excludes Loop and
/// Bounce (playbackStyle == .imageAnimated); keeps Live and Long Exposure
/// (playbackStyle == .livePhoto).
private actor LivePhotoScanner {
    func scan() -> [LivePhotoItem] {
        let options = PHFetchOptions()
        // Only assets flagged as Live Photos are candidates.
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0",
            PHAssetMediaSubtype.photoLive.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var items: [LivePhotoItem] = []
        assets.enumerateObjects { asset, _, _ in
            // Keep only genuine Live Photos and Long Exposure; exclude Loop and
            // Bounce. LivePhotoVariation reads the effect type (with a public
            // playbackStyle fallback).
            guard LivePhotoVariation.of(asset).isConvertibleToStill else { return }
            guard let date = asset.creationDate else { return }
            items.append(LivePhotoItem(id: asset.localIdentifier, date: date))
        }
        return items
    }
}
