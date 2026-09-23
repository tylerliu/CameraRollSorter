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
    var threshold: Float = 0.4
    private var photos: [TimedPhoto] = []
    private var unavailablePhotoIDs: Set<String> = []
    private let analyzer = SimilarityAnalyzer()
    var isScanning = false
    var hasScanned = false
    var revision = UUID()
    private var scanTask: Task<Void, Never>?
    // Debounces the destructive prune after scan-scope (direction/date) changes,
    // so rapid adjustments don't drop results that a later change brings back.
    private var windowPruneTask: Task<Void, Never>?
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
    // Scan direction/start-date config captured at the last scan, so
    // `applySettings` can reconcile changes without a needless full rescan.
    private var lastScanDirection: ScanDirection = .older
    private var lastScanStartDate: Date?

    // Incremental scan state. Photos are sorted once, then processed in
    // date-ordered batches on demand so a huge library doesn't block on one
    // giant Vision pass. Scanning pauses once `targetGroupCount` groups exist
    // and resumes when the list scrolls near the end.
    private var sortedPhotos: [TimedPhoto] = []
    // IDs of photos whose neighborhoods have been measured as anchors. Tracked
    // as a set (not a prefix count) so it survives reordering: flipping scan
    // direction keeps every measured photo measured, no re-scan needed.
    private var scannedIDs: Set<String> = []
    // Photo IDs in the order they were scanned. Drives the *display* order so
    // newly scanned groups always append to the back of the list. Flipping the
    // scan direction reverses this (the visible list reverses) while continued
    // scanning keeps appending to the end.
    private var scanProgression: [String] = []
    // Furthest group row the viewer has reached. The scan keeps ~targetGroupCount
    // groups scanned ahead of this, so the buffer rolls forward as you scroll.
    private var scanAheadOf = 0
    // Top-visible group id, so the Similar list restores scroll position when
    // navigating away and back within a session. Not persisted across launches.
    var scrollAnchorID: String?
    // Anchors processed per incremental step. The initial scan uses a larger
    // batch to fill the first results quickly; once scanned, forward scanning
    // (driven by scrolling) uses a smaller batch so it stays responsive and
    // results appear more incrementally.
    private let initialBatchSize = 256
    private let forwardBatchSize = 64
    private var batchSize: Int { hasScanned ? forwardBatchSize : initialBatchSize }
    /// True while the Similar photos list is on screen. Off → the scan only
    /// fills the small preview buffer (home screen); on → it fills the full
    /// buffer. Set via `setListActive`.
    private var listActive = false
    /// True while a batch is actively measuring (drives the bottom spinner).
    var isScanningBatch = false
    /// True when there are still unscanned photos in the current window.
    var hasMoreToScan: Bool { sortedPhotos.contains { !scannedIDs.contains($0.id) } }

    /// Capture-date span of all accessible photos, or nil before the first scan
    /// / when the library is empty. Used to bound and seed the start-date
    /// picker so a date with no photos can't be chosen.
    var libraryDateRange: ClosedRange<Date>? {
        guard let min = photos.map(\.date).min(), let max = photos.map(\.date).max(), min <= max else {
            return nil
        }
        return min...max
    }

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
        windowPruneTask?.cancel()
        groups = []
        pairs = []
        photos = []
        unavailablePhotoIDs = []
        analysisError = nil
        revision = UUID()
        hasScanned = false
        isScanning = false
        fetchResult = nil
        guard canRead else { return }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        sortedPhotos = []
        scannedIDs = []
        scanProgression = []
        scanAheadOf = 0
        scrollAnchorID = nil
        isScanning = true
        scanTask = Task {
            let result = await scanner.scan()
            guard !Task.isCancelled else { return }
            photos = result.photos
            fetchResult = result.fetchResult
            sortedPhotos = SequenceGrouping.scanOrdered(
                result.photos,
                direction: scanDirectionSetting,
                startDate: scanStartDateSetting
            )
            scannedIDs = []
            scanProgression = []
            // Capture the geo-gate config this scan runs under.
            recordGeoConfig()
            // Fill the initial buffer of groups from the front of the list.
            scanAheadOf = 0
            await runBatches()
            guard !Task.isCancelled else { return }
            hasScanned = true
            isScanning = false
        }
    }

    /// Keep the scanned list filled to ~`targetGroupCount` groups AHEAD of the
    /// row the user is viewing (a rolling window, not a hard total cap). Called
    /// as rows appear. No-op while a batch is already running or nothing
    /// remains. `currentIndex` is the group row that triggered this.
    func scanMore(currentIndex: Int = 0) {
        // Track the furthest-viewed position so an in-flight scan loop extends
        // its buffer target as the user scrolls (rather than stopping short).
        scanAheadOf = max(scanAheadOf, currentIndex)
        guard canRead, hasMoreToScan, !isScanning else { return }
        isScanning = true
        let token = revision
        scanTask = Task {
            // Scan until there are enough groups beyond the viewed position, or
            // the library is exhausted. Keeps the buffer ahead of the viewer.
            await runBatches()
            if revision == token { isScanning = false }
        }
    }

    /// Called when the Similar photos list appears/disappears. Opening the list
    /// lifts the buffer from the small home-screen preview cap to the full one,
    /// so scanning resumes to fill it; closing it just stops growing the buffer.
    func setListActive(_ active: Bool) {
        listActive = active
        if active { scanMore() }
    }

    /// Measure successive `batchSize` slices of `sortedPhotos`, appending pairs
    /// and regrouping after each. Stops when the library is exhausted or once
    /// there are `targetGroupCount` groups AHEAD of the viewer's position
    /// (`scanAheadOf`, updated live by `scanMore` as the list scrolls) — a
    /// rolling buffer, not a hard total cap.
    private func runBatches() async {
        let token = revision
        while hasMoreToScan {
            if Task.isCancelled || revision != token { return }
            // Enough buffer ahead of the current position → pause. Uses the
            // small preview cap until the list is open, then the full buffer.
            if groups.count - scanAheadOf >= ScanBuffer.effectiveTarget(listActive: listActive) { break }

            // Next batch: the first `batchSize` still-unscanned photos in scan
            // order. Usually a contiguous front run, but after a direction flip
            // they can be scattered, so select by index explicitly.
            let batchAnchorIndices = sortedPhotos.indices
                .filter { !scannedIDs.contains(sortedPhotos[$0].id) }
                .prefix(batchSize)
            var neighborhoods: [CandidateNeighborhood] = []
            for anchorIndex in batchAnchorIndices {
                neighborhoods += SequenceGrouping.neighborhoods(in: sortedPhotos, anchorRange: anchorIndex..<(anchorIndex + 1))
            }
            let batchAnchorIDs = Set(batchAnchorIndices.map { sortedPhotos[$0].id })
            // Reuse the measurement cache: skip pairs we already have scores
            // for. After a direction/start change we clear the display but keep
            // `pairs`, so re-covering overlapping photos costs no Vision work.
            let measured = Set(pairs.map { CandidateComparison($0.first, $0.second) })
            let batchComparisons = geoFilteredComparisons(for: neighborhoods)
                .filter { !measured.contains($0) }

            isScanningBatch = true
            // Compute the valid-id set ONCE per batch (not per callback) so
            // appends stay cheap as pairs grow.
            let ids = Set(photos.map(\.id))
            do {
                let scores = try await analyzer.analyzeComparisons(
                    batchComparisons,
                    partialResults: { [self] newPairs in
                        guard self.revision == token else { return }
                        self.pairs.append(contentsOf: newPairs.filter {
                            ids.contains($0.first) && ids.contains($0.second)
                        })
                        // Regroup at most ~5×/sec during a batch instead of on
                        // every 5-pair callback; a full regroup is O(photos+pairs)
                        // and runs on the main actor, so coalescing avoids the lag.
                        self.applyThresholdThrottled()
                    }
                )
                guard revision == token, !Task.isCancelled else { isScanningBatch = false; return }
                // Dedup against pairs already delivered via partialResults using
                // a Set lookup (was an O(newPairs × pairs) linear scan).
                var knownPairIDs = Set(pairs.map(\.id))
                pairs.append(contentsOf: scores.pairs.filter { score in
                    ids.contains(score.first) && ids.contains(score.second)
                        && knownPairIDs.insert(score.id).inserted
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

            // Record scan-progression order (skip any already recorded). Iterate
            // sortedPhotos so within-batch order follows the scan traversal.
            for index in batchAnchorIndices {
                let id = sortedPhotos[index].id
                if !scannedIDs.contains(id) { scanProgression.append(id) }
            }
            scannedIDs.formUnion(batchAnchorIDs)
            applyThreshold()
        }
        isScanningBatch = false
    }

    // Last time a live regroup ran, to coalesce the frequent partial-results
    // regroups during a batch (a full regroup is O(photos+pairs) on main).
    private var lastLiveRegroup = Date.distantPast
    private let liveRegroupInterval = 0.2

    /// Regroup at most every `liveRegroupInterval` seconds. Used for the
    /// streaming partial results; the authoritative regroup still runs once at
    /// the end of each batch via `applyThreshold()`.
    private func applyThresholdThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastLiveRegroup) >= liveRegroupInterval else { return }
        lastLiveRegroup = now
        applyThreshold()
    }

    func applyThreshold() {
        threshold = Float(UserDefaults.standard.object(forKey: "review.distanceThreshold") as? Double ?? 0.4)
        // Group in *scan-progression* order so newly scanned groups append to
        // the back of the list. Only photos actually scanned (in progression)
        // anchor the display — this is what lets a window change CLEAR the view
        // and rebuild from the new front even though `pairs` is still cached.
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shown = Set(scanProgression)
        var seen = Set<String>()
        var ordered: [TimedPhoto] = []
        for id in scanProgression where seen.insert(id).inserted {
            if let photo = byID[id] { ordered.append(photo) }
        }
        // Pull in neighbors of scanned photos so a group never drops a member,
        // but ONLY when the neighbor's pair touches a scanned (shown) photo.
        // Pairs among not-yet-shown photos stay hidden until they're scanned.
        for pair in pairs where shown.contains(pair.first) || shown.contains(pair.second) {
            for id in [pair.first, pair.second] where seen.insert(id).inserted {
                if let photo = byID[id] { ordered.append(photo) }
            }
        }
        groups = SimilarityGrouping.groups(photos: ordered, pairs: pairs, threshold: threshold)
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

    /// Snapshot the geo-gate and scan-order config used by the current scan, so
    /// `applySettings` can tell whether (and how) a change needs reconciling.
    private func recordGeoConfig() {
        lastScanGeoEnabled = Self.geoGateEnabledSetting
        lastScanGeoKilometers = Self.geoGateKilometersSetting
        lastScanDirection = scanDirectionSetting
        lastScanStartDate = scanStartDateSetting
    }

    private static var geoGateEnabledSetting: Bool {
        UserDefaults.standard.object(forKey: "review.geoGateEnabled") as? Bool ?? true
    }
    private static var geoGateKilometersSetting: Double {
        UserDefaults.standard.object(forKey: "review.geoGateKilometers") as? Double ?? 1.0
    }
    // Per-view scan-window state, bound to the pinned ScanControlsHeader. NOT
    // shared with the Live→Still screen — each list has its own window.
    var scanDirectionRaw = "older"
    var scanStartEnabled = false
    var scanStartInterval = 0.0

    private var scanDirectionSetting: ScanDirection {
        ScanDirection(rawValue: scanDirectionRaw) ?? .older
    }
    /// The configured scan start date, or nil when "from date" is off.
    private var scanStartDateSetting: Date? {
        guard scanStartEnabled, scanStartInterval > 0 else { return nil }
        return Date(timeIntervalSince1970: scanStartInterval)
    }

    /// Called when the settings sheet closes. Reconciles the current results
    /// with any changed setting, doing the least work needed:
    /// - geo-gate change → full re-scan (changes which pairs get measured)
    /// - direction / start-date change → additive reorder + scan immediately,
    ///   with the destructive prune of out-of-window results debounced 2s
    /// - threshold / group-target only → regroup, optionally resume to new cap
    func applySettings() {
        let geoChanged = Self.geoGateEnabledSetting != lastScanGeoEnabled
            || (Self.geoGateEnabledSetting && Self.geoGateKilometersSetting != lastScanGeoKilometers)
        if geoChanged {
            // Geo gate changes which pairs get measured → full re-scan.
            refresh()
            return
        }

        let newDirection = scanDirectionSetting
        let newStart = scanStartDateSetting

        // Scan-scope change (direction and/or start date). Two layers:
        //   • View: the shown groups are no longer valid for the new setting, so
        //     clear the display and re-populate from the new window's front
        //     (e.g. oldest first when flipping to Old→New).
        //   • Data: keep the measured `pairs` as a cache. The fresh scan reuses
        //     them (no Vision re-run for overlapping photos), so the list fills
        //     quickly; and if the setting changes again within 2s the cache is
        //     still intact. A debounced prune drops out-of-window cache entries
        //     once changes settle.
        if newDirection != lastScanDirection || newStart != lastScanStartDate,
           hasScanned || isScanning {
            lastScanDirection = newDirection
            lastScanStartDate = newStart
            restartScanForWindow(direction: newDirection, startDate: newStart)
            scheduleCachePrune(direction: newDirection, startDate: newStart)
            return
        }

        lastScanDirection = newDirection
        lastScanStartDate = newStart

        // Threshold / group-target change only: regroup, resume if below buffer.
        applyThreshold()
        if hasMoreToScan, groups.count < ScanBuffer.effectiveTarget(listActive: listActive), !isScanning {
            isScanning = true
            let token = revision
            scanTask = Task {
                await runBatches()
                if revision == token { isScanning = false }
            }
        }
    }

    /// Re-populate the view for a new scan window. Clears the displayed
    /// progression and scan cursor so the list rebuilds from the new front, but
    /// KEEPS `pairs` (the measurement cache) so re-covering overlapping photos
    /// costs no Vision work. Starts scanning up to the group cap.
    private func restartScanForWindow(direction: ScanDirection, startDate: Date?) {
        scanTask?.cancel()
        sortedPhotos = SequenceGrouping.scanOrdered(photos, direction: direction, startDate: startDate)
        // View reset: forget what's "shown as scanned" so the display rebuilds
        // from the new front. `pairs` stays as the reuse cache.
        scannedIDs = []
        scanProgression = []
        scanAheadOf = 0
        scrollAnchorID = nil
        revision = UUID()
        applyThreshold()   // clears the visible list immediately
        isScanning = true
        let token = revision
        scanTask = Task {
            await runBatches()
            // Only clear the flag if this is still the current scan; a superseded
            // (cancelled) task must not stomp a newer scan's isScanning = true.
            if revision == token { isScanning = false }
        }
    }

    /// Debounced data-layer cleanup: after the last scan-scope change settles,
    /// drop cached pairs for photos no longer in the window. Reruns reset the
    /// timer, so a burst of adjustments prunes once. The delay is generous so a
    /// user still deciding on a date in the calendar (which can pause well over
    /// a couple seconds between taps) doesn't evict the reuse cache — the prune
    /// is purely a memory optimization and never affects the displayed list.
    private func scheduleCachePrune(direction: ScanDirection, startDate: Date?) {
        windowPruneTask?.cancel()
        windowPruneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.pruneCacheToWindow(direction: direction, startDate: startDate)
        }
    }

    /// Drop cached pairs/photos no longer in the given window. Only runs if the
    /// window is still current (settings didn't change again afterward).
    private func pruneCacheToWindow(direction: ScanDirection, startDate: Date?) {
        guard direction == lastScanDirection, startDate == lastScanStartDate else { return }
        let keepIDs = Set(SequenceGrouping.scanOrdered(photos, direction: direction, startDate: startDate).map(\.id))
        pairs.removeAll { !keepIDs.contains($0.first) || !keepIDs.contains($0.second) }
        unavailablePhotoIDs.formIntersection(keepIDs)
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
        photos.removeAll { identifiers.contains($0.id) }
        pairs.removeAll { identifiers.contains($0.first) || identifiers.contains($0.second) }
        unavailablePhotoIDs.subtract(identifiers)

        // Drop removed photos from the scan set and ordered arrays.
        sortedPhotos.removeAll { identifiers.contains($0.id) }
        scannedIDs.subtract(identifiers)
        scanProgression.removeAll { identifiers.contains($0) }

        // Deletion can only remove edges and split groups — never create a new
        // similar pair. So no Vision work is needed; just regroup from the
        // surviving measured edges.
        applyThreshold()
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

        guard !added.isEmpty || !removed.isEmpty else { return }

        analysisError = nil

        // Rebuild the scan-ordered array from the new library snapshot, honoring
        // the current direction and start-date window. `scannedIDs` survives the
        // rebuild unchanged — removed IDs are pruned below, added IDs aren't in
        // it yet.
        photos = result.photos
        fetchResult = result.fetchResult
        sortedPhotos = SequenceGrouping.scanOrdered(
            result.photos,
            direction: scanDirectionSetting,
            startDate: scanStartDateSetting
        )
        unavailablePhotoIDs.subtract(removed)
        scannedIDs.subtract(removed)

        // Drop pairs referencing removed photos. (Deletion only removes edges.)
        if !removed.isEmpty {
            pairs.removeAll { removed.contains($0.first) || removed.contains($0.second) }
        }

        // An added photo should be measured now if it lands *within* the region
        // we've already scanned — i.e. at or before the last scanned photo in
        // scan order. Photos beyond that frontier are in the unscanned tail and
        // scanMore will reach them. Work positionally so it's correct for either
        // scan direction.
        let frontierIndex = sortedPhotos.lastIndex { scannedIDs.contains($0.id) }
        var addedInsideWindow: [String] = []
        if let frontierIndex {
            for index in 0...frontierIndex where added.contains(sortedPhotos[index].id) {
                addedInsideWindow.append(sortedPhotos[index].id)
            }
        }

        // Measure only the neighborhoods of photos newly added inside the
        // scanned window. Their neighborhoods reach existing neighbors on both
        // sides, so cross pairs are covered. Photos added beyond the window are
        // handled later by scanMore.
        guard !addedInsideWindow.isEmpty else {
            applyThreshold()
            isScanning = false
            hasScanned = true
            return
        }

        let token = UUID()
        revision = token
        isScanning = true
        hasScanned = false

        let addedSet = Set(addedInsideWindow)
        // These added photos sit in the already-scanned region and are being
        // measured now, so they join the scanned set and progression. Their
        // displayed group position is governed by the earliest existing member
        // of whatever component they join, so appending here is fine.
        scannedIDs.formUnion(addedSet)
        for id in addedInsideWindow where !scanProgression.contains(id) { scanProgression.append(id) }
        let anchorIndices = sortedPhotos.indices.filter { addedSet.contains(sortedPhotos[$0].id) }
        var neighborhoods: [CandidateNeighborhood] = []
        for anchorIndex in anchorIndices {
            neighborhoods += SequenceGrouping.neighborhoods(in: sortedPhotos, anchorRange: anchorIndex..<(anchorIndex + 1))
        }
        let measured = Set(pairs.map { CandidateComparison($0.first, $0.second) })
        let missingComparisons = geoFilteredComparisons(for: neighborhoods)
            .filter { !measured.contains($0) }
        guard !missingComparisons.isEmpty else {
            applyThreshold()
            isScanning = false
            hasScanned = true
            return
        }
        do {
            let scores = try await analyzer.analyzeComparisons(
                missingComparisons,
                partialResults: { [weak self] newPairs in
                    guard let self, self.revision == token else { return }
                    self.pairs.append(contentsOf: newPairs)
                    self.applyThresholdThrottled()
                }
            )
            guard revision == token else { return }
            let currentIDs = Set(photos.map(\.id))
            var knownPairIDs = Set(pairs.map(\.id))
            pairs.append(contentsOf: scores.pairs.filter { score in
                currentIDs.contains(score.first) && currentIDs.contains(score.second)
                    && knownPairIDs.insert(score.id).inserted
            })
            unavailablePhotoIDs.formUnion(scores.unavailableIDs.intersection(currentIDs))
            applyThreshold()
        } catch is CancellationError {
            return
        } catch {
            guard revision == token else { return }
            analysisError = "Similarity analysis failed: \(error.localizedDescription). Pull to refresh to retry."
        }
        isScanning = false
        hasScanned = true
    }
}

private actor SequenceScanner {
    struct Result: Sendable {
        let photos: [TimedPhoto]
        // The fetch result this scan enumerated, so the caller can diff future
        // change notifications against it. PHFetchResult is thread-safe.
        let fetchResult: PHFetchResult<PHAsset>
    }

    func scan() -> Result {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var photos: [TimedPhoto] = []
        assets.enumerateObjects { asset, _, _ in
            if let date = asset.creationDate {
                let coordinate = asset.location?.coordinate
                photos.append(TimedPhoto(
                    id: asset.localIdentifier,
                    date: date,
                    latitude: coordinate?.latitude,
                    longitude: coordinate?.longitude
                ))
            }
        }
        return Result(photos: photos, fetchResult: assets)
    }
}
