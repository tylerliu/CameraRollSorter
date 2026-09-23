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

@MainActor @Observable
final class LiveToStillModel: NSObject, PHPhotoLibraryChangeObserver {
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
    private var observing = false

    // Incremental scan state. The candidate Live Photos are fetched once (fast,
    // metadata only) and ordered by the direction/start-date window. They are
    // then classified in batches on demand so a large library never stalls: the
    // grid shows results as they stream in and keeps a rolling buffer ahead of
    // the scroll position.
    private var allCandidates: [TimedPhoto] = [] // full fetched candidate set (unwindowed)
    private var candidates: [TimedPhoto] = []    // ordered+windowed candidate Live Photos
    private var classifiedCount = 0              // how far along `candidates` we've classified
    private let batchSize = 200                 // candidates classified per step
    // Furthest grid row the viewer reached; the scan keeps `ScanBuffer.target`
    // items classified ahead of it (a shared, settings-driven buffer).
    private var scanAheadOf = 0
    private var lastScanDirection: ScanDirection = .older
    private var lastScanStartDate: Date?
    // True while the grid is on screen. Off → only the small preview buffer is
    // filled (home screen); on → the full buffer. Set via `setListActive`.
    private var listActive = false

    var canRead: Bool { authorization == .authorized || authorization == .limited }

    /// True while there are still unclassified candidates in the window.
    var hasMoreToScan: Bool { classifiedCount < candidates.count }

    /// Capture-date span of all Live Photo candidates, to bound/seed the
    /// start-date picker. nil before the first scan or when there are none.
    var libraryDateRange: ClosedRange<Date>? {
        guard let min = allCandidates.map(\.date).min(),
              let max = allCandidates.map(\.date).max(), min <= max else { return nil }
        return min...max
    }

    // Per-view scan-window state, bound to the pinned ScanControlsHeader. NOT
    // shared with the Similar photos screen — each list has its own window.
    var scanDirectionRaw = "older"
    var scanStartEnabled = false
    var scanStartInterval = 0.0

    private var scanDirectionSetting: ScanDirection {
        ScanDirection(rawValue: scanDirectionRaw) ?? .older
    }
    private var scanStartDateSetting: Date? {
        guard scanStartEnabled, scanStartInterval > 0 else { return nil }
        return Date(timeIntervalSince1970: scanStartInterval)
    }

    /// Scan for convertible Live Photos incrementally. Fetches the candidate set
    /// fast (metadata predicate), orders it by the current direction/start-date
    /// window, then classifies in buffered batches so the UI stays responsive.
    func scan() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else {
            items = []
            hasScanned = false
            return
        }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        scanTask?.cancel()
        errorMessage = nil
        items = []
        allCandidates = []
        candidates = []
        classifiedCount = 0
        scanAheadOf = 0
        scrollAnchorID = nil
        isScanning = true
        lastScanDirection = scanDirectionSetting
        lastScanStartDate = scanStartDateSetting
        scanTask = Task {
            // Fast metadata-only fetch of every Live Photo candidate. Ordering
            // and classification (Live vs Loop/Bounce/Long) are deferred so
            // nothing blocks up front.
            let found = await scanner.fetchCandidates()
            guard !Task.isCancelled else { return }
            allCandidates = found
            candidates = SequenceGrouping.scanOrdered(
                found, direction: scanDirectionSetting, startDate: scanStartDateSetting
            )
            hasScanned = true
            await classifyBatches()
            isScanning = false
        }
    }

    /// Classify the next unclassified candidates on demand as the grid scrolls.
    func scanMore(currentIndex: Int = 0) {
        scanAheadOf = max(scanAheadOf, currentIndex)
        guard canRead, hasMoreToScan, !isScanning else { return }
        isScanning = true
        scanTask = Task {
            await classifyBatches()
            isScanning = false
        }
    }

    /// Called when the grid appears/disappears. Opening it lifts the buffer from
    /// the home-screen preview cap to the full one, resuming classification.
    func setListActive(_ active: Bool) {
        listActive = active
        if active { scanMore() }
    }

    /// Classify successive `batchSize` slices of `candidates`, appending the
    /// convertible ones to `items`. Stops when the candidate list is exhausted
    /// or once there are `ScanBuffer.target` items classified beyond the viewed
    /// position. Yields between batches so the UI stays responsive.
    private func classifyBatches() async {
        while hasMoreToScan {
            if Task.isCancelled { return }
            if items.count - scanAheadOf >= ScanBuffer.effectiveTarget(listActive: listActive) { break }

            let start = classifiedCount
            let end = min(start + batchSize, candidates.count)
            let batchIDs = candidates[start..<end].map(\.id)
            let convertible = await scanner.convertibleItems(in: batchIDs)
            if Task.isCancelled { return }
            // Preserve window order: `convertibleItems` returns them keyed, we
            // append in candidate order.
            let byID = Dictionary(convertible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in batchIDs {
                if let item = byID[id] { items.append(item) }
            }
            classifiedCount = end
            await Task.yield()
        }
    }

    /// Called when the direction/start-date controls change. Restarts the view
    /// (clears the grid, re-populates from the new window front) while keeping
    /// the fetched candidate set for reuse; a debounced task prunes if needed.
    func applyScanSettings() {
        let newDirection = scanDirectionSetting
        let newStart = scanStartDateSetting
        guard newDirection != lastScanDirection || newStart != lastScanStartDate else { return }
        lastScanDirection = newDirection
        lastScanStartDate = newStart

        scanTask?.cancel()
        // Re-window from the FULL fetched candidate set (not the previously
        // windowed subset) so widening the window brings items back. Rebuild
        // from the front.
        candidates = SequenceGrouping.scanOrdered(
            allCandidates, direction: newDirection, startDate: newStart
        )
        items = []
        classifiedCount = 0
        scanAheadOf = 0
        scrollAnchorID = nil
        isScanning = true
        scanTask = Task {
            await classifyBatches()
            isScanning = false
        }
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // PhotoKit delivers this on a background thread; do all work on the main
        // actor. A converted/added/deleted photo changes the candidate set, so
        // reconcile incrementally rather than resetting the grid.
        Task { @MainActor [weak self] in await self?.syncLibrary() }
    }

    /// Incrementally reconcile the grid with the current library — used on
    /// library changes and scene-activation — WITHOUT resetting scroll. Fetches
    /// the candidate set fresh, then adds/removes items in place:
    /// - removed candidates drop out of `items`/`candidates`/`allCandidates`
    /// - added candidates are appended to the unclassified tail so scanMore
    ///   reaches them; any already inside the classified window are classified
    ///   now and inserted in window order.
    func syncLibrary() async {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else { items = []; hasScanned = false; return }
        // If we never scanned, a plain scan is correct (nothing to preserve).
        guard hasScanned, !isScanning else { if !hasScanned { scan() }; return }

        let found = await scanner.fetchCandidates()
        let oldIDs = Set(allCandidates.map(\.id))
        let newIDs = Set(found.map(\.id))
        let added = newIDs.subtracting(oldIDs)
        let removed = oldIDs.subtracting(newIDs)
        guard !added.isEmpty || !removed.isEmpty else { return }

        allCandidates = found

        // Remove dropped photos everywhere. Preserves scroll: SwiftUI keeps the
        // remaining rows in place rather than resetting.
        if !removed.isEmpty {
            items.removeAll { removed.contains($0.id) }
        }

        // Rebuild the windowed candidate list from the fresh set, then figure
        // out how far we'd classified (by matching already-shown items).
        let shownIDs = Set(items.map(\.id))
        candidates = SequenceGrouping.scanOrdered(
            found, direction: scanDirectionSetting, startDate: scanStartDateSetting
        )
        // The classified frontier is the furthest candidate index whose id is
        // already shown; anything added at or before it should be classified now.
        let frontier = candidates.lastIndex { shownIDs.contains($0.id) }
        classifiedCount = (frontier ?? -1) + 1

        // Classify any added candidates that fall within the frontier and insert
        // them in window order. Added photos beyond the frontier stay in the
        // unclassified tail for scanMore.
        let addedInside = added.isEmpty ? [] : candidates.prefix(classifiedCount).map(\.id).filter { added.contains($0) }
        if !addedInside.isEmpty {
            let newItems = await scanner.convertibleItems(in: addedInside)
            let convertibleAdded = Set(newItems.map(\.id))
            // Rebuild `items` in window order over the classified prefix so the
            // new ones land in their correct position (not at the end).
            let itemByID = Dictionary(
                (items + newItems).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
            )
            var rebuilt: [LivePhotoItem] = []
            for cand in candidates.prefix(classifiedCount) {
                if shownIDs.contains(cand.id) || convertibleAdded.contains(cand.id),
                   let item = itemByID[cand.id] {
                    rebuilt.append(item)
                }
            }
            items = rebuilt
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
    /// Fast metadata-only fetch of every Live Photo candidate (id + date). No
    /// per-asset classification here, so it returns quickly even for a large
    /// library. Classification happens later, in batches, via `convertibleItems`.
    func fetchCandidates() -> [TimedPhoto] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0",
            PHAssetMediaSubtype.photoLive.rawValue
        )
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var result: [TimedPhoto] = []
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            result.append(TimedPhoto(id: asset.localIdentifier, date: date))
        }
        return result
    }

    /// Classify a batch of candidate ids, returning only those convertible to a
    /// plain still (genuine Live and Long Exposure — never Loop/Bounce).
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
