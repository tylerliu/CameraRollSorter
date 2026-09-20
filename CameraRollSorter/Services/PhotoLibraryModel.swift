import Foundation
import Photos
import Observation
import UIKit

enum PhotoLibraryDeletionError: LocalizedError {
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

@MainActor @Observable
final class PhotoLibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var groups: [PhotoSequence] = []
    var pairs: [SimilarityPair] = []
    var analysisError: String?
    var progress = ""
    var threshold: Float = 0.4
    private var photos: [TimedPhoto] = []
    private var accessiblePhotoCount = 0
    private var missingDateCount = 0
    private var unavailablePhotoIDs: Set<String> = []
    private let analyzer = SimilarityAnalyzer()
    var isScanning = false
    var hasScanned = false
    var summary = ""
    var revision = UUID()
    private var scanTask: Task<Void, Never>?
    private let scanner = SequenceScanner()
    private var observing = false
    // The fetch result backing the last scan. Retained so change notifications
    // can be diffed with PHChange.changeDetails(for:) — the only reliable way to
    // tell whether a library change actually affects OUR accessible set. A
    // camera capture that isn't in the limited selection produces no change
    // details here, so it costs nothing.
    private var fetchResult: PHFetchResult<PHAsset>?
    // Geo-gate config captured at the last scan, so settings changes know
    // whether a re-scan is actually needed. Initialized to the defaults.
    private var lastScanGeoEnabled = true
    private var lastScanGeoKilometers = 1.0

    // Incremental scan state. Photos are sorted once, then processed in
    // date-ordered batches on demand so a huge library doesn't block on one
    // giant Vision pass. Scanning pauses once `targetGroupCount` groups exist
    // and resumes when the list scrolls near the end.
    private var sortedPhotos: [TimedPhoto] = []
    private var scannedAnchorCount = 0          // how far along sortedPhotos we've measured
    private let batchSize = 256                 // anchors processed per incremental step
    // Soft stop for the initial scan: pause once this many groups exist. User
    // configurable in review settings (default 500).
    private var targetGroupCount: Int {
        let value = UserDefaults.standard.object(forKey: "review.initialGroupTarget") as? Int ?? 500
        return max(1, value)
    }
    /// True while a batch is actively measuring (drives the bottom spinner).
    var isScanningBatch = false
    /// True when there are still unscanned photos beyond the current window.
    var hasMoreToScan: Bool { scannedAnchorCount < sortedPhotos.count }

    var canRead: Bool { authorization == .authorized || authorization == .limited }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func syncLibrary() async {
        let previous = authorization
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorization = current

        let couldRead = previous == .authorized || previous == .limited
        let canReadNow = current == .authorized || current == .limited

        // Only a full reset when readability itself changes (gained or lost
        // access). Staying readable — including limited→limited after selecting
        // more photos, or granting more under limited access — is an incremental
        // library change, not a reason to rescan everything.
        if canReadNow != couldRead {
            refresh()
            return
        }
        guard canReadNow else { return }
        await reconcileLibraryChange()
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        scanTask?.cancel()
        groups = []
        pairs = []
        photos = []
        unavailablePhotoIDs = []
        analysisError = nil
        progress = "Reading photo dates…"
        revision = UUID()
        hasScanned = false
        isScanning = false
        fetchResult = nil
        guard canRead else { summary = ""; return }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        sortedPhotos = []
        scannedAnchorCount = 0
        isScanning = true
        scanTask = Task {
            let result = await scanner.scan()
            guard !Task.isCancelled else { return }
            photos = result.photos
            fetchResult = result.fetchResult
            sortedPhotos = SequenceGrouping.sortedByDate(result.photos)
            scannedAnchorCount = 0
            accessiblePhotoCount = result.count
            missingDateCount = result.missingDates
            // Capture the geo-gate config this scan runs under.
            recordGeoConfig()
            updateSummary()
            // Process batches until the soft group cap or the library is done.
            await runBatches(untilGroupCap: true)
            guard !Task.isCancelled else { return }
            hasScanned = true
            isScanning = false
        }
    }

    /// Process the next batch of photos on demand (called as the list scrolls
    /// near the end). No-op while a batch is already running or nothing remains.
    func scanMore() {
        // No-op if we can't read, nothing remains, or a scan loop is already
        // running (initial scan or a prior scanMore).
        guard canRead, hasMoreToScan, !isScanning else { return }
        isScanning = true
        scanTask = Task {
            // Scroll-driven: advance one batch past the cap so the list keeps
            // filling as the user scrolls beyond the first 500 groups.
            await runBatches(untilGroupCap: false, maxBatches: 1)
            isScanning = false
        }
    }

    /// Measure successive `batchSize` slices of `sortedPhotos`, appending pairs
    /// and regrouping after each. Stops when the library is exhausted or, if
    /// `untilGroupCap`, once `targetGroupCount` groups exist.
    private func runBatches(untilGroupCap: Bool, maxBatches: Int = .max) async {
        let token = revision
        var processed = 0
        while hasMoreToScan {
            if Task.isCancelled || revision != token { return }
            if untilGroupCap && groups.count >= targetGroupCount { break }
            if processed >= maxBatches { break }
            processed += 1

            let start = scannedAnchorCount
            let end = min(start + batchSize, sortedPhotos.count)
            let neighborhoods = SequenceGrouping.neighborhoods(in: sortedPhotos, anchorRange: start..<end)
            let batchComparisons = geoFilteredComparisons(for: neighborhoods)

            isScanningBatch = true
            progress = "Comparing photos… \(end) of \(sortedPhotos.count)"
            do {
                let scores = try await analyzer.analyzeComparisons(
                    batchComparisons,
                    progress: { _, _ in },
                    partialResults: { [self] newPairs in
                        guard self.revision == token else { return }
                        let ids = Set(self.photos.map(\.id))
                        self.pairs.append(contentsOf: newPairs.filter {
                            ids.contains($0.first) && ids.contains($0.second)
                        })
                        self.applyThreshold()
                    }
                )
                guard revision == token, !Task.isCancelled else { isScanningBatch = false; return }
                let ids = Set(photos.map(\.id))
                pairs.append(contentsOf: scores.pairs.filter { score in
                    ids.contains(score.first) && ids.contains(score.second)
                        && !pairs.contains { $0.id == score.id }
                })
                unavailablePhotoIDs.formUnion(scores.unavailableIDs.intersection(ids))
            } catch is CancellationError {
                isScanningBatch = false
                return
            } catch {
                analysisError = "Similarity analysis failed: \(error.localizedDescription). Pull to refresh to retry."
                isScanningBatch = false
                return
            }

            scannedAnchorCount = end
            updateSummary()
            applyThreshold()
        }
        isScanningBatch = false
        progress = hasMoreToScan ? "Paused — scroll for more" : "Scan complete"
    }

    func applyThreshold() {
        threshold = Float(UserDefaults.standard.object(forKey: "review.distanceThreshold") as? Double ?? 0.4)
        groups = SimilarityGrouping.groups(photos: photos, pairs: pairs, threshold: threshold)
    }

    private func updateSummary() {
        summary = "\(accessiblePhotoCount) accessible photos across your library. \(missingDateCount) accessible photos have no capture date and cannot be grouped. \(unavailablePhotoIDs.count) candidate photos unavailable locally."
    }

    /// Build the comparison list for the given neighborhoods, applying the
    /// geo-proximity gate when enabled in settings. Skipping distant pairs here
    /// (before Vision) is what saves the work.
    private func geoFilteredComparisons(for groups: [CandidateNeighborhood]) -> [CandidateComparison] {
        let all = SequenceGrouping.comparisons(groups)
        guard Self.geoGateEnabledSetting else { return all }
        let km = Self.geoGateKilometersSetting
        return SequenceGrouping.geoFiltered(all, photos: photos, maxMeters: max(0, km) * 1000)
    }

    /// Snapshot the geo-gate config used by the current scan, so `applySettings`
    /// can tell whether a change requires a re-scan.
    private func recordGeoConfig() {
        lastScanGeoEnabled = Self.geoGateEnabledSetting
        lastScanGeoKilometers = Self.geoGateKilometersSetting
    }

    private static var geoGateEnabledSetting: Bool {
        UserDefaults.standard.object(forKey: "review.geoGateEnabled") as? Bool ?? true
    }
    private static var geoGateKilometersSetting: Double {
        UserDefaults.standard.object(forKey: "review.geoGateKilometers") as? Double ?? 1.0
    }

    /// Called when the settings sheet closes. A threshold change only needs a
    /// regroup; a geo-gate change (toggle or distance) changes which pairs get
    /// measured, so it needs a full re-scan.
    func applySettings() {
        let geoChanged = Self.geoGateEnabledSetting != lastScanGeoEnabled
            || (Self.geoGateEnabledSetting && Self.geoGateKilometersSetting != lastScanGeoKilometers)
        if geoChanged {
            // Geo gate changes which pairs get measured → full re-scan.
            refresh()
            return
        }
        // Threshold change only regroups existing scores.
        applyThreshold()
        // If the group target was raised above what we've found, resume the
        // initial scan up to the new cap (no re-scan of measured photos).
        if hasMoreToScan, groups.count < targetGroupCount, !isScanning {
            isScanning = true
            scanTask = Task {
                await runBatches(untilGroupCap: true)
                isScanning = false
            }
        }
    }

    func scores(for group: PhotoSequence) -> [SimilarityPair] {
        let ids = Set(group.photos.map(\.id))
        let candidates = pairs.filter { ids.contains($0.first) && ids.contains($0.second) }
        return SimilarityGrouping.minimumSpanningTree(photos: group.photos, pairs: candidates, threshold: threshold)
    }

    @discardableResult
    func deletePhotos(_ identifiers: Set<String>) async throws -> Int {
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoLibraryDeletionError.writeAccessRequired
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else { return 0 }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibraryDeletionError.changeRejected)
                }
            }
        }
        removeFromCurrentResults(Set(assets.map(\.localIdentifier)))
        return assets.count
    }

    private func removeFromCurrentResults(_ identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        let previousCount = photos.count
        photos.removeAll { identifiers.contains($0.id) }
        let removedDatedPhotos = previousCount - photos.count
        accessiblePhotoCount = max(0, accessiblePhotoCount - removedDatedPhotos)
        pairs.removeAll { identifiers.contains($0.first) || identifiers.contains($0.second) }
        unavailablePhotoIDs.subtract(identifiers)

        // Keep the incremental cursor consistent: any removed photo that sat
        // within the scanned prefix shrinks it by one, since the prefix is an
        // exact slice of `sortedPhotos`.
        var removedWithinScanned = 0
        for index in sortedPhotos.indices where identifiers.contains(sortedPhotos[index].id) {
            if index < scannedAnchorCount { removedWithinScanned += 1 }
        }
        sortedPhotos.removeAll { identifiers.contains($0.id) }
        scannedAnchorCount = max(0, scannedAnchorCount - removedWithinScanned)

        updateSummary()
        // Deletion can only remove edges and split groups — never create a new
        // similar pair. So no Vision work is needed; just regroup from the
        // surviving measured edges.
        applyThreshold()
        progress = "Library updated"
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // PhotoKit delivers this on an arbitrary background thread, so we must
        // NOT touch main-actor state (like `fetchResult`) here — doing so traps.
        // `PHChange` is safe to hand to the main actor; we do all diffing there.
        Task { @MainActor [weak self] in
            guard let self, let fetchResult = self.fetchResult else { return }
            // Diff against the fetch result our last scan enumerated. If the
            // change doesn't touch OUR accessible set — e.g. a camera capture
            // that isn't in the limited selection — changeDetails is nil and we
            // do nothing. This is what stops taking a photo from re-scanning.
            guard let details = changeInstance.changeDetails(for: fetchResult) else { return }
            // Advance our retained fetch result to the post-change state so the
            // next notification diffs correctly.
            self.fetchResult = details.fetchResultAfterChanges
            await self.syncLibrary()
        }
    }

    private func reconcileLibraryChange() async {
        guard canRead else {
            refresh()
            return
        }
        // A scan already in flight reads current PhotoKit state. Avoid replacing it
        // with another library-wide pass when PhotoKit emits duplicate callbacks.
        guard hasScanned, !isScanning else { return }

        let result = await scanner.scan()
        let oldIDs = Set(photos.map(\.id))
        let newIDs = Set(result.photos.map(\.id))
        let added = newIDs.subtracting(oldIDs)
        let removed = oldIDs.subtracting(newIDs)

        guard !added.isEmpty || !removed.isEmpty else {
            accessiblePhotoCount = result.count
            missingDateCount = result.missingDates
            updateSummary()
            return
        }

        analysisError = nil
        accessiblePhotoCount = result.count
        missingDateCount = result.missingDates

        // Identify which currently-scanned photos survive, to preserve the
        // scanned prefix across the rebuild. The prefix is the set of photo ids
        // in sortedPhotos[..<scannedAnchorCount].
        let previouslyScannedIDs = Set(sortedPhotos.prefix(scannedAnchorCount).map(\.id))

        // Rebuild the date-sorted array from the new library snapshot.
        photos = result.photos
        fetchResult = result.fetchResult
        sortedPhotos = SequenceGrouping.sortedByDate(result.photos)
        unavailablePhotoIDs.subtract(removed)

        // Drop pairs referencing removed photos. (Deletion only removes edges.)
        if !removed.isEmpty {
            pairs.removeAll { removed.contains($0.first) || removed.contains($0.second) }
        }

        // An added photo belongs to the "already scanned" region if its
        // date-sorted position falls among previously-scanned survivors — i.e.
        // it is not newer than the last previously-scanned photo. Rebuild the
        // scanned prefix to include such additions; leave later ones for the
        // unscanned tail (normal scanMore will reach them).
        let lastScannedDate = sortedPhotos
            .filter { previouslyScannedIDs.contains($0.id) }
            .map(\.date).max()

        var newScannedCount = 0
        var addedInsideWindow: [String] = []
        for (index, photo) in sortedPhotos.enumerated() {
            let wasScanned = previouslyScannedIDs.contains(photo.id)
            let isNewInsideWindow: Bool = {
                guard added.contains(photo.id), let lastScannedDate else { return false }
                // Inside the window if not strictly newer than the frontier.
                return photo.date <= lastScannedDate
            }()
            if wasScanned || isNewInsideWindow {
                newScannedCount = index + 1
                if isNewInsideWindow { addedInsideWindow.append(photo.id) }
            }
        }
        scannedAnchorCount = min(newScannedCount, sortedPhotos.count)

        // Measure only the neighborhoods of photos newly added inside the
        // scanned window. Their neighborhoods reach existing neighbors on both
        // sides, so cross pairs are covered. Photos added beyond the window are
        // handled later by scanMore.
        guard !addedInsideWindow.isEmpty else {
            updateSummary()
            applyThreshold()
            progress = "Library updated"
            isScanning = false
            hasScanned = true
            return
        }

        let token = UUID()
        revision = token
        isScanning = true
        hasScanned = false

        let addedSet = Set(addedInsideWindow)
        let anchorIndices = sortedPhotos.indices.filter { addedSet.contains(sortedPhotos[$0].id) }
        var neighborhoods: [CandidateNeighborhood] = []
        for anchorIndex in anchorIndices {
            neighborhoods += SequenceGrouping.neighborhoods(in: sortedPhotos, anchorRange: anchorIndex..<(anchorIndex + 1))
        }
        let measured = Set(pairs.map { CandidateComparison($0.first, $0.second) })
        let missingComparisons = geoFilteredComparisons(for: neighborhoods)
            .filter { !measured.contains($0) }
        guard !missingComparisons.isEmpty else {
            updateSummary()
            applyThreshold()
            progress = "Library updated"
            isScanning = false
            hasScanned = true
            return
        }
        do {
            let scores = try await analyzer.analyzeComparisons(
                missingComparisons,
                progress: { [weak self] completed, total in
                    guard let self, self.revision == token else { return }
                    self.progress = "Comparing library changes: \(completed) of \(total) pairs"
                },
                partialResults: { [weak self] newPairs in
                    guard let self, self.revision == token else { return }
                    self.pairs.append(contentsOf: newPairs)
                    self.applyThreshold()
                }
            )
            guard revision == token else { return }
            let currentIDs = Set(photos.map(\.id))
            pairs.append(contentsOf: scores.pairs.filter { score in
                currentIDs.contains(score.first) && currentIDs.contains(score.second)
                    && !pairs.contains { $0.id == score.id }
            })
            unavailablePhotoIDs.formUnion(scores.unavailableIDs.intersection(currentIDs))
            updateSummary()
            applyThreshold()
        } catch is CancellationError {
            return
        } catch {
            guard revision == token else { return }
            analysisError = "Similarity analysis failed: \(error.localizedDescription). Pull to refresh to retry."
        }
        progress = "Library updated"
        isScanning = false
        hasScanned = true
    }
}

private actor SequenceScanner {
    struct Result: Sendable {
        let groups: [CandidateNeighborhood]
        let photos: [TimedPhoto]
        let count: Int
        let missingDates: Int
        // The fetch result this scan enumerated, so the caller can diff future
        // change notifications against it. PHFetchResult is thread-safe.
        let fetchResult: PHFetchResult<PHAsset>
    }

    func scan() -> Result {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var photos: [TimedPhoto] = []
        var missing = 0
        assets.enumerateObjects { asset, _, _ in
            if let date = asset.creationDate {
                let coordinate = asset.location?.coordinate
                photos.append(TimedPhoto(
                    id: asset.localIdentifier,
                    date: date,
                    latitude: coordinate?.latitude,
                    longitude: coordinate?.longitude
                ))
            } else { missing += 1 }
        }
        return Result(groups: SequenceGrouping.groups(photos), photos: photos, count: photos.count, missingDates: missing, fetchResult: assets)
    }
}
