import Foundation
import Observation
import Photos

/// A detected blurry photo. Parallels `LivePhotoItem`; `variance` is the
/// Laplacian-variance blur score, kept for debugging and future score blending.
struct BlurryPhotoItem: Identifiable, Sendable {
    let id: String          // PHAsset.localIdentifier
    let date: Date
    let variance: Double     // Laplacian variance; lower means more blur
}

/// Errors surfaced by the blurry-photos deletion flow. Parallels
/// `PhotoLibraryDeletionError`, with user-facing messages.
enum BlurryPhotosError: LocalizedError {
    case writeAccessRequired
    case changeRejected

    var errorDescription: String? {
        switch self {
        case .writeAccessRequired:
            return "Photo access does not allow changes. Grant full or limited read-write access and try again."
        case .changeRejected:
            return "Photos did not accept the deletion request."
        }
    }
}

/// Pure candidate predicate mirroring the scan fetch predicate: an asset is in
/// scope iff it is an image (`.image` media type, which already excludes videos)
/// and is not a screenshot (`PHAssetMediaSubtype.photoScreenshot`). Live Photos
/// are ordinary `.image` assets and are intentionally admitted; they are scored
/// on their still frame. Extracted so scan scope (Requirements 3.1–3.3) can be
/// checked without PhotoKit.
func isScannable(mediaType: PHAssetMediaType, mediaSubtypes: PHAssetMediaSubtype) -> Bool {
    guard mediaType == .image else { return false }
    return !mediaSubtypes.contains(.photoScreenshot)
}

/// Background actor that finds blurry-photo candidates and classifies them.
/// Mirrors `LivePhotoScanner`: the fetch is metadata-only and fast; the
/// per-batch classification does the image decode + Laplacian-variance work.
private actor BlurryPhotoScanner {
    /// Fast metadata-only fetch of every scan candidate (id + date). The
    /// `.image` media type already excludes videos (Requirements 3.1, 3.2), and
    /// the predicate masks out screenshots (Requirement 3.3). Live Photos are
    /// ordinary `.image` assets and are intentionally kept; they are classified
    /// on their still frame later. Assets without a capture date are skipped.
    func fetchCandidates() -> [TimedPhoto] {
        let options = PHFetchOptions()
        // Keep only assets whose subtype does NOT include screenshot.
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) == 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var result: [TimedPhoto] = []
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            result.append(TimedPhoto(id: asset.localIdentifier, date: date))
        }
        return result
    }

    /// Classify a batch of candidate ids, returning only those whose Laplacian
    /// variance is below `cutoff`, in candidate order. Each id is scored inside
    /// its own `autoreleasepool` so the decoded image buffers are released
    /// promptly across a large batch. Ids whose downscaled image can't be
    /// loaded locally are dropped (Requirement 2.6).
    func blurryItems(in ids: [String], cutoff: Double) -> [BlurryPhotoItem] {
        var items: [BlurryPhotoItem] = []
        for id in ids {
            autoreleasepool {
                guard let variance = BlurClassifier.laplacianVariance(for: id) else { return }
                guard variance < cutoff else { return }
                guard let date = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                    .firstObject?.creationDate else { return }
                items.append(BlurryPhotoItem(id: id, date: date, variance: variance))
            }
        }
        return items
    }
}

/// Per-screen scan model for the Blurry photos flow. A near-clone of
/// `LiveToStillModel`: candidates are fetched fast (metadata only), ordered and
/// windowed with `SequenceGrouping.scanOrdered`, then classified in buffered
/// batches on `BlurryPhotoScanner` so a large library streams in rather than
/// blocking. "Convertible Live Photo" classification is replaced by blur
/// classification against the active variance cutoff.
///
/// NOTE: `applySensitivity()`, `syncLibrary()`, `photoLibraryDidChange(_:)`, and
/// `deletePhotos(_:)` are added by later tasks (4.3 / 4.4). This task (4.2)
/// implements the scan lifecycle only. A minimal `photoLibraryDidChange`
/// placeholder is present so the `PHPhotoLibraryChangeObserver` conformance
/// compiles; task 4.3 fleshes it out.
@MainActor @Observable
final class BlurryPhotosModel: NSObject, PHPhotoLibraryChangeObserver {
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var items: [BlurryPhotoItem] = []
    var isScanning = false
    var hasScanned = false
    var errorMessage: String?
    // Remembers the top-visible grid item so scroll position is restored when
    // navigating away and back within a session. Not persisted across launches.
    var scrollAnchorID: String?

    private let scanner = BlurryPhotoScanner()
    private var scanTask: Task<Void, Never>?
    private var observing = false

    // Incremental scan state. The candidate photos are fetched once (fast,
    // metadata only) and ordered by the direction/start-date window. They are
    // then classified in batches on demand so a large library never stalls: the
    // grid shows results as they stream in and keeps a rolling buffer ahead of
    // the scroll position.
    private var allCandidates: [TimedPhoto] = [] // full fetched candidate set (unwindowed)
    private var candidates: [TimedPhoto] = []    // ordered+windowed candidate photos
    private var classifiedCount = 0              // how far along `candidates` we've classified
    // Fewer per batch than Live→Still: each item does an image decode +
    // Laplacian convolution, so smaller batches keep the UI responsive.
    private let batchSize = 120                  // candidates classified per step
    // Furthest grid row the viewer reached; keep this many items classified
    // ahead of it.
    private var scanAheadOf = 0
    private let targetBufferAhead = 300
    private var lastScanDirection: ScanDirection = .older
    private var lastScanStartDate: Date?
    // Cutoff captured at scan start so a mid-scan settings change is handled by
    // `applySensitivity()` rather than racing the batches.
    private var activeCutoff: Double = BlurSensitivity.currentCutoff

    var canRead: Bool { authorization == .authorized || authorization == .limited }

    /// True while there are still unclassified candidates in the window.
    var hasMoreToScan: Bool { classifiedCount < candidates.count }

    /// Capture-date span of all photo candidates, to bound/seed the start-date
    /// picker. nil before the first scan or when there are none.
    var libraryDateRange: ClosedRange<Date>? {
        guard let min = allCandidates.map(\.date).min(),
              let max = allCandidates.map(\.date).max(), min <= max else { return nil }
        return min...max
    }

    // Per-view scan-window state, bound to the pinned ScanControlsHeader. NOT
    // shared with the other cleanup screens — each list has its own window.
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

    /// Scan for blurry photos incrementally. Fetches the candidate set fast
    /// (metadata predicate), orders it by the current direction/start-date
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
        // Capture the cutoff for this scan so a mid-scan settings change is
        // reconciled by applySensitivity() rather than racing classifyBatches().
        activeCutoff = BlurSensitivity.currentCutoff
        scanTask = Task {
            // Fast metadata-only fetch of every candidate. Ordering and the
            // per-image blur classification are deferred so nothing blocks up front.
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

    /// Classify successive `batchSize` slices of `candidates`, appending the
    /// blurry ones to `items`. Stops when the candidate list is exhausted or
    /// once there are `targetBufferAhead` items classified beyond the viewed
    /// position. Yields between batches so the UI stays responsive.
    private func classifyBatches() async {
        while hasMoreToScan {
            if Task.isCancelled { return }
            if items.count - scanAheadOf >= targetBufferAhead { break }

            let start = classifiedCount
            let end = min(start + batchSize, candidates.count)
            let batchIDs = candidates[start..<end].map(\.id)
            let blurry = await scanner.blurryItems(in: batchIDs, cutoff: activeCutoff)
            if Task.isCancelled { return }
            // Preserve window order: `blurryItems` returns candidate-ordered
            // results, but append via lookup to keep the invariant explicit.
            let byID = Dictionary(blurry.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in batchIDs {
                if let item = byID[id] { items.append(item) }
            }
            classifiedCount = end
            await Task.yield()
        }
    }

    /// Called when the direction/start-date controls change. Restarts the view
    /// (clears the grid, re-populates from the new window front) while keeping
    /// the fetched candidate set for reuse.
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

    /// Called when the sensitivity (variance cutoff) setting changes. No-ops
    /// when the cutoff is unchanged, so it's cheap to call on every settings
    /// dismiss (Requirement 7.4).
    ///
    /// The re-check is ASYMMETRIC, exploiting that the blur decision is
    /// monotonic in the cutoff (blurry when variance < cutoff):
    /// - LOWERING the cutoff (less sensitive): the new blurry set is a SUBSET of
    ///   the current one. Every photo that still qualifies was already flagged
    ///   and carries its stored `variance`, so we simply re-filter `items` in
    ///   place — no re-scan, no classifier work, and scroll position is kept
    ///   because we only remove rows. `classifiedCount`/`candidates` are left
    ///   untouched: we've merely tightened the filter over the same classified
    ///   prefix, and any later batches classified via `classifyBatches` will use
    ///   the new (lower) `activeCutoff` too, so results stay consistent.
    /// - RAISING the cutoff (more sensitive): photos that previously passed can
    ///   now qualify, but their variances were never retained, so a full re-scan
    ///   over the same candidate window from the front is required.
    func applySensitivity() {
        let newCutoff = BlurSensitivity.currentCutoff
        guard newCutoff != activeCutoff else { return }
        let loweringCutoff = newCutoff < activeCutoff
        activeCutoff = newCutoff
        if loweringCutoff {
            // LESS sensitive: the new blurry set is a SUBSET of the current
            // results. Every newly-blurry photo was already flagged, so just
            // re-filter the current items in place by their stored variance —
            // no re-scan, no classifier work. This also keeps scroll position
            // (we only remove rows).
            scanTask?.cancel()
            items = items.filter { BlurSensitivity.isBlurry(variance: $0.variance, cutoff: newCutoff) }
            // Note: classifiedCount/candidates are unchanged — we've merely
            // tightened the filter over the SAME already-classified prefix. Do
            // NOT reset them.
            isScanning = false
        } else {
            // MORE sensitive: photos that previously passed can now qualify, and
            // their variances were never retained, so a full re-scan over the
            // same candidate window from the front is required.
            scanTask?.cancel()
            items = []
            classifiedCount = 0
            scanAheadOf = 0
            isScanning = true
            scanTask = Task {
                await classifyBatches()
                isScanning = false
            }
        }
    }

    /// Delete the selected photos with a single batched asset-deletion request,
    /// mirroring `PhotoLibraryModel.deletePhotos`. There is **no** in-app
    /// confirmation dialog: the OS Recently Deleted prompt is the only gate
    /// (Requirement 8.4). Guards write authorization first — if changes aren't
    /// permitted it throws `writeAccessRequired` and leaves `items` untouched
    /// (Requirement 8.6). Runs exactly one `performChanges` block; on success it
    /// removes the deleted ids from `items` and returns the count (Requirement
    /// 8.5). On failure/cancel the continuation throws (`changeRejected` or the
    /// underlying error) and `items` is left unchanged (Requirement 8.7).
    /// Errors are also surfaced via `errorMessage` for the view's alert.
    @discardableResult
    func deletePhotos(_ identifiers: Set<String>) async throws -> Int {
        guard canRead else {
            errorMessage = BlurryPhotosError.writeAccessRequired.errorDescription
            throw BlurryPhotosError.writeAccessRequired
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else { return 0 }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: BlurryPhotosError.changeRejected)
                    }
                }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }

        removeFromCurrentResults(Set(assets.map(\.localIdentifier)))
        return assets.count
    }

    /// Drop the deleted ids from every result surface so the grid and the
    /// windowed/full candidate sets stay consistent after a deletion. Parallels
    /// `PhotoLibraryModel.removeFromCurrentResults`.
    private func removeFromCurrentResults(_ identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        items.removeAll { identifiers.contains($0.id) }
        candidates.removeAll { identifiers.contains($0.id) }
        allCandidates.removeAll { identifiers.contains($0.id) }
        classifiedCount = min(classifiedCount, candidates.count)
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // PhotoKit delivers this on a background thread; do all work on the main
        // actor. An added/deleted photo changes the candidate set, so reconcile
        // incrementally rather than resetting the grid.
        Task { @MainActor [weak self] in await self?.syncLibrary() }
    }

    /// Incrementally reconcile the grid with the current library — used on
    /// library changes and scene-activation — WITHOUT resetting scroll. Fetches
    /// the candidate set fresh, then adds/removes items in place:
    /// - removed candidates drop out of `items`/`candidates`/`allCandidates`
    /// - added candidates are appended to the unclassified tail so scanMore
    ///   reaches them; any already inside the classified window are classified
    ///   now and inserted in window order.
    /// `scrollAnchorID` is preserved throughout (no scroll reset, Requirement 9.3).
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
            let newItems = await scanner.blurryItems(in: addedInside, cutoff: activeCutoff)
            let blurryAdded = Set(newItems.map(\.id))
            // Rebuild `items` in window order over the classified prefix so the
            // new ones land in their correct position (not at the end).
            let itemByID = Dictionary(
                (items + newItems).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
            )
            var rebuilt: [BlurryPhotoItem] = []
            for cand in candidates.prefix(classifiedCount) {
                if shownIDs.contains(cand.id) || blurryAdded.contains(cand.id),
                   let item = itemByID[cand.id] {
                    rebuilt.append(item)
                }
            }
            items = rebuilt
        }
    }
}
