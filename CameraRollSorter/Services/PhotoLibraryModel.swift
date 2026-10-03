import Foundation
import Photos
import Observation

enum PhotoLibraryDeletionError: LocalizedError {
    case writeAccessRequired
    case changeRejected

    var errorDescription: String? {
        switch self {
        case .writeAccessRequired:
            return String(localized: "Photo access does not allow changes. Grant full or limited read-write access and try again.")
        case .changeRejected:
            return String(localized: "Photos did not accept the deletion request.")
        }
    }
}

@MainActor @Observable
final class PhotoLibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var groups: [PhotoSequence] = []
    // Measured pairs (the Vision cache). Only mutated through
    // `appendMeasuredPairs` / `removePairs` so `measuredComparisons` stays in
    // sync with it.
    private(set) var pairs: [SimilarityPair] = []
    // Keys of every pair in `pairs`, kept alongside it so "already measured?"
    // and dedup checks are O(1) instead of rebuilding a set of all pairs per
    // batch.
    private var measuredComparisons: Set<CandidateComparison> = []
    // Similarity groups maintained incrementally from `pairs` and
    // `scanProgression`; published into `groups`. Rebuilt by `applyThreshold()`.
    // Not observed: views read `groups`.
    @ObservationIgnored private var grouping = IncrementalSimilarityGrouping(threshold: 0.4)
    var analysisError: String?
    var threshold: Float = 0.4
    // All accessible photos. The id lookup and date span are derived here once
    // per change rather than rebuilt on every batch / regroup / header render.
    private var photos: [TimedPhoto] = [] { didSet { rebuildPhotoIndex() } }
    private var photosByID: [String: TimedPhoto] = [:]
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
    private var lastScanDirection: ScanDirection = .newer
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
    // Bottom-most group row currently on screen. The scan keeps ~targetGroupCount
    // groups scanned ahead of it, so the buffer rolls forward as you scroll down
    // and the scan pauses (after the photo in flight) when you scroll back up.
    private var scanAheadOf = 0
    // Top-visible group id, so the Similar list restores scroll position when
    // navigating away and back within a session. Not persisted across launches.
    var scrollAnchorID: String?
    // Anchors handed to the analyzer per call. Anchors report as they finish
    // and feature prints are cached across calls, so this only bounds how much
    // work is planned at once; it doesn't delay results or add Vision work.
    private let batchSize = 64
    /// True while the Similar photos list is on screen. Off → the scan only
    /// fills the small preview buffer (home screen); on → it fills the full
    /// buffer. Set via `setListActive`.
    private var listActive = false
    /// True while a batch is actively measuring (drives the bottom spinner).
    var isScanningBatch = false
    // Index of the first not-yet-scanned photo in `sortedPhotos`; everything
    // before it is scanned. Keeps batch selection and `hasMoreToScan` cheap
    // instead of re-filtering the whole library each time. `runBatches`
    // advances it; any other change to `sortedPhotos` or `scannedIDs` must call
    // `resetScanCursor()`.
    private var scanCursor = 0
    /// True when there are still unscanned photos in the current window.
    var hasMoreToScan: Bool { scanCursor < sortedPhotos.count }

    /// Capture-date span of all accessible photos, or nil before the first scan
    /// / when the library is empty. Used to bound and seed the start-date
    /// picker so a date with no photos can't be chosen. Derived when `photos`
    /// changes (it's read on every header render).
    private(set) var libraryDateRange: ClosedRange<Date>?

    /// Rebuild the id lookup and date span after `photos` changes.
    private func rebuildPhotoIndex() {
        photosByID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var lower: Date?
        var upper: Date?
        for photo in photos {
            if lower == nil || photo.date < lower! { lower = photo.date }
            if upper == nil || photo.date > upper! { upper = photo.date }
        }
        if let lower, let upper { libraryDateRange = lower...upper } else { libraryDateRange = nil }
    }

    /// Recompute `scanCursor` from scratch. O(photos); only for the rare events
    /// that rebuild or reshuffle the scan set (rescan, window change, deletion,
    /// library reconcile).
    private func resetScanCursor() {
        scanCursor = sortedPhotos.firstIndex { !scannedIDs.contains($0.id) } ?? sortedPhotos.count
    }

    /// Move `scanCursor` past photos that are now scanned. Amortized O(1).
    private func advanceScanCursor() {
        while scanCursor < sortedPhotos.count, scannedIDs.contains(sortedPhotos[scanCursor].id) {
            scanCursor += 1
        }
    }

    /// Append newly measured pairs, skipping duplicates and pairs whose photos
    /// are no longer in the library (e.g. deleted mid-batch).
    private func appendMeasuredPairs(_ newPairs: [SimilarityPair]) {
        var accepted: [SimilarityPair] = []
        for pair in newPairs where photosByID[pair.first] != nil && photosByID[pair.second] != nil {
            if measuredComparisons.insert(CandidateComparison(pair.first, pair.second)).inserted {
                accepted.append(pair)
                grouping.addPair(pair)
            }
        }
        if !accepted.isEmpty { pairs.append(contentsOf: accepted) }
    }

    /// Remove pairs matching `predicate` and resync the measured-key set.
    /// O(pairs), but only used on rare events (deletion, prune, reconcile).
    private func removePairs(where predicate: (SimilarityPair) -> Bool) {
        pairs.removeAll(where: predicate)
        measuredComparisons = Set(pairs.map { CandidateComparison($0.first, $0.second) })
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
        measuredComparisons = []
        threshold = Self.thresholdSetting
        grouping = IncrementalSimilarityGrouping(threshold: threshold)
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
        scanCursor = 0
        scanProgression = []
        scanAheadOf = 0
        scrollAnchorID = nil
        isScanning = true
        let token = revision
        scanTask = Task {
            let result = await scanner.scan()
            // If a newer refresh took over (revision changed) it owns the flag;
            // otherwise this cancelled task must still clear `isScanning` so the
            // home-row spinner doesn't strand on a near-empty library at launch.
            guard !Task.isCancelled else {
                if revision == token { isScanning = false }
                return
            }
            photos = result.photos
            fetchResult = result.fetchResult
            sortedPhotos = SequenceGrouping.scanOrdered(
                result.photos,
                direction: scanDirectionSetting,
                startDate: scanStartDateSetting
            )
            scannedIDs = []
            scanCursor = 0
            scanProgression = []
            // Capture the geo-gate config this scan runs under.
            recordGeoConfig()
            // Fill the initial buffer of groups from the front of the list.
            scanAheadOf = 0
            await runBatches()
            guard revision == token else { return }
            hasScanned = true
            isScanning = false
        }
    }

    /// Keep the scanned list filled to ~`targetGroupCount` groups AHEAD of the
    /// row the user is viewing (a rolling window, not a hard total cap). Called
    /// as rows appear and disappear with the bottom-most visible row (or the
    /// group count when the list's end is visible). Moving down can resume a
    /// paused scan; moving up lowers the target, so a running scan pauses at its
    /// next progress check.
    func scanMore(currentIndex: Int) {
        scanAheadOf = currentIndex
        resumeIfNeeded()
    }

    /// Start scanning if the buffer ahead of the viewer isn't full and nothing
    /// is running.
    private func resumeIfNeeded() {
        guard canRead, hasMoreToScan, !isScanning, !bufferFull else { return }
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
        if active { resumeIfNeeded() }
    }

    // True while another cleanup feature's screen is open, so this scan
    // doesn't compete with it for Vision time. Set by the home screen.
    private var isPaused = false

    /// Pause (after the photo in flight) or resume this scan.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused { resumeIfNeeded() }
    }

    /// True when the scan should stop: paused, or enough groups buffered ahead
    /// of the viewer (the small preview cap until the list is open, then the
    /// full buffer).
    private var bufferFull: Bool {
        isPaused || groups.count - scanAheadOf >= ScanBuffer.effectiveTarget(listActive: listActive)
    }

    /// Measure successive `batchSize` slices of `sortedPhotos`, appending pairs
    /// and regrouping after each. Stops when the library is exhausted or once
    /// there are `targetGroupCount` groups AHEAD of the viewer's position
    /// (`scanAheadOf`, updated live by `scanMore` as the list scrolls either
    /// way) — a rolling buffer, not a hard total cap.
    private func runBatches() async {
        let token = revision
        while hasMoreToScan {
            if Task.isCancelled || revision != token { return }
            if bufferFull { break }

            // Next batch: the first `batchSize` still-unscanned photos in scan
            // order, walking forward from the cursor (everything before it is
            // scanned). Usually a contiguous run; photos already scanned out of
            // order (e.g. added inside the window by a reconcile) are skipped.
            var batchAnchorIndices: [Int] = []
            var index = scanCursor
            while index < sortedPhotos.count, batchAnchorIndices.count < batchSize {
                if !scannedIDs.contains(sortedPhotos[index].id) { batchAnchorIndices.append(index) }
                index += 1
            }
            // Per-anchor work, in scan order. Each comparison belongs to the
            // first anchor in the batch that needs it, so an anchor is complete
            // once its own list is measured (earlier anchors already covered
            // the rest). Skip pairs already in the measurement cache: after a
            // direction/start change we clear the display but keep `pairs`, so
            // re-covering overlapping photos costs no Vision work. Anchor IDs
            // are captured now, since a deletion during the batch reshuffles
            // `sortedPhotos`.
            var assigned: Set<CandidateComparison> = []
            var work: [SimilarityAnalyzer.AnchorWork] = []
            for anchorIndex in batchAnchorIndices {
                let neighborhood = SequenceGrouping.neighborhoods(in: sortedPhotos, anchorRange: anchorIndex..<(anchorIndex + 1))
                let comparisons = geoFilteredComparisons(for: neighborhood)
                    .filter { !measuredComparisons.contains($0) && assigned.insert($0).inserted }
                work.append(.init(anchor: sortedPhotos[anchorIndex].id, comparisons: comparisons))
            }

            isScanningBatch = true
            do {
                let scores = try await analyzer.analyze(work) { [self] newPairs, completed in
                    guard self.revision == token else { return false }
                    self.appendMeasuredPairs(newPairs)
                    // Show each anchor's group as soon as the anchor is done,
                    // rather than at the end of the batch.
                    self.markScanned(completed)
                    // Publish at most ~5×/sec so the list doesn't re-render
                    // constantly.
                    self.publishGroupsThrottled()
                    // Stop mid-batch once the buffer ahead of the viewer is
                    // full or the scan is paused; unfinished anchors stay
                    // unscanned for later.
                    return !self.bufferFull
                }
                guard revision == token, !Task.isCancelled else { isScanningBatch = false; return }
                // Every pair was already streamed through progress; this is a
                // cheap dedup'd catch-all.
                appendMeasuredPairs(scores.pairs)
                unavailablePhotoIDs.formUnion(scores.unavailableIDs.filter { photosByID[$0] != nil })
            } catch is CancellationError {
                isScanningBatch = false
                return
            } catch {
                analysisError = "Similarity analysis failed: \(error.localizedDescription). Pull to refresh to retry."
                isScanningBatch = false
                return
            }
            publishGroups()
        }
        isScanningBatch = false
    }

    // Last time streamed results were published, to coalesce the frequent
    // partial-results updates during a batch. Grouping itself is incremental;
    // this limits how often the list re-renders.
    private var lastLiveRegroup = Date.distantPast
    private let liveRegroupInterval = 0.2

    /// Publish at most every `liveRegroupInterval` seconds. Used for the
    /// streaming partial results; each batch end publishes unconditionally.
    private func publishGroupsThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastLiveRegroup) >= liveRegroupInterval else { return }
        lastLiveRegroup = now
        publishGroups()
    }

    /// Mark finished anchors as scanned, in the order given (scan order). Skips
    /// photos already recorded and any deleted while their batch ran.
    private func markScanned(_ ids: [String]) {
        for id in ids where photosByID[id] != nil && scannedIDs.insert(id).inserted {
            scanProgression.append(id)
            grouping.markShown(id)
        }
        advanceScanCursor()
    }

    /// Copy the incremental grouping's pending changes into `groups`. Cost is
    /// proportional to the groups that changed.
    private func publishGroups() {
        if grouping.flush(photosByID: photosByID) { groups = grouping.groups }
    }

    private static var thresholdSetting: Float {
        Float(UserDefaults.standard.object(forKey: "review.distanceThreshold") as? Double ?? 0.4)
    }

    /// Full regroup from scratch: re-reads the threshold and rebuilds the
    /// incremental grouping from the current scan state. O(photos + pairs), so
    /// it's only used for global changes — threshold change, scan-window
    /// restart, library reconcile, cache prune. Streaming results and
    /// deletions update the grouping incrementally instead.
    func applyThreshold() {
        threshold = Self.thresholdSetting
        grouping = IncrementalSimilarityGrouping(
            threshold: threshold,
            progression: scanProgression,
            pairs: pairs,
            photosByID: photosByID
        )
        grouping.flush(photosByID: photosByID)
        groups = grouping.groups
    }

    /// Build the comparison list for the given neighborhoods, applying the
    /// geo-proximity gate when enabled in settings. Skipping distant pairs here
    /// (before Vision) is what saves the work.
    private func geoFilteredComparisons(for groups: [CandidateNeighborhood]) -> [CandidateComparison] {
        let all = SequenceGrouping.comparisons(groups)
        guard Self.geoGateEnabledSetting else { return all }
        let km = Self.geoGateKilometersSetting
        return SequenceGrouping.geoFiltered(all, byID: photosByID, maxMeters: max(0, km) * 1000)
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
    // shared with the other cleanup screens — each list has its own window,
    // persisted under its own key prefix so it survives app relaunch.
    private let windowStore = ScanWindowStore(prefix: "similar")
    var scanDirectionRaw = "newer" { didSet { windowStore.direction = scanDirectionRaw } }
    var scanStartEnabled = false { didSet { windowStore.startEnabled = scanStartEnabled } }
    var scanStartInterval = 0.0 { didSet { windowStore.startInterval = scanStartInterval } }

    override init() {
        super.init()
        // Restore the persisted scan window. These assignments re-write the same
        // values back through didSet, which is an idempotent no-op.
        scanDirectionRaw = windowStore.direction
        scanStartEnabled = windowStore.startEnabled
        scanStartInterval = windowStore.startInterval
        // Keep the last-scan markers in sync with the restored window so the
        // first applySettings() doesn't see a phantom change.
        lastScanDirection = scanDirectionSetting
        lastScanStartDate = scanStartDateSetting
    }

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
        // Gate on the library being loaded (`fetchResult` is set once the
        // fetch completes), not on `hasScanned`: that flag isn't set if the
        // first scan is cancelled, which made later window changes fall through
        // to the threshold-only path and never restart. While the initial fetch
        // is still running, skip the restart (it would window an empty photo
        // list and cancel the fetch); the fetch windows with the current
        // settings when it lands.
        if newDirection != lastScanDirection || newStart != lastScanStartDate,
           fetchResult != nil {
            lastScanDirection = newDirection
            lastScanStartDate = newStart
            restartScanForWindow(direction: newDirection, startDate: newStart)
            // NOTE: the destructive cache prune is NOT scheduled here. It only
            // runs when the user settles the scan window (closes the date
            // roller, changes the order, or toggles the date window off) via
            // `scheduleWindowCleanup()`. Opening the roller cancels it. This
            // keeps the reuse cache intact while the user is still picking.
            return
        }

        lastScanDirection = newDirection
        lastScanStartDate = newStart

        // Threshold / group-target change only: regroup, resume if below buffer.
        applyThreshold()
        resumeIfNeeded()
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
        scanCursor = 0
        scanProgression = []
        scanAheadOf = 0
        scrollAnchorID = nil
        revision = UUID()
        applyThreshold()   // clears the visible list immediately
        // The library is loaded and windowed. Set this here too, since a
        // restart cancels the initial scan before it would have set it.
        hasScanned = true
        isScanning = true
        let token = revision
        scanTask = Task {
            await runBatches()
            // Only clear the flag if this is still the current scan; a superseded
            // (cancelled) task must not stomp a newer scan's isScanning = true.
            if revision == token { isScanning = false }
        }
    }

    /// Schedule the debounced data-layer cleanup after the user SETTLES the scan
    /// window — closing the date roller, changing the order, or toggling the
    /// date window off. Drops cached pairs for photos no longer in the current
    /// window 2s later. Reruns reset the timer, so a burst of settles prunes
    /// once. The prune is purely a memory optimization and never affects the
    /// displayed list. Opening the roller again cancels it via
    /// `cancelWindowCleanup()`, so nothing is evicted while the user is still
    /// deciding.
    func scheduleWindowCleanup() {
        let direction = lastScanDirection
        let startDate = lastScanStartDate
        windowPruneTask?.cancel()
        windowPruneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.pruneCacheToWindow(direction: direction, startDate: startDate)
        }
    }

    /// Cancel any pending window cleanup. Called when the date roller opens, so
    /// the reuse cache survives while the user is still picking a date.
    func cancelWindowCleanup() {
        windowPruneTask?.cancel()
    }

    /// Drop cached pairs/photos no longer in the given window. Only runs if the
    /// window is still current (settings didn't change again afterward).
    private func pruneCacheToWindow(direction: ScanDirection, startDate: Date?) {
        guard direction == lastScanDirection, startDate == lastScanStartDate else { return }
        let keepIDs = Set(SequenceGrouping.scanOrdered(photos, direction: direction, startDate: startDate).map(\.id))
        removePairs { !keepIDs.contains($0.first) || !keepIDs.contains($0.second) }
        unavailablePhotoIDs.formIntersection(keepIDs)
        // The grouping indexes every pair; resync it with the pruned set.
        applyThreshold()
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
        removePairs { identifiers.contains($0.first) || identifiers.contains($0.second) }
        unavailablePhotoIDs.subtract(identifiers)

        // Drop removed photos from the scan set and ordered arrays.
        sortedPhotos.removeAll { identifiers.contains($0.id) }
        scannedIDs.subtract(identifiers)
        resetScanCursor()   // indices shifted
        scanProgression.removeAll { identifiers.contains($0) }

        // Deletion can only remove edges and split groups — never create a new
        // similar pair. So no Vision work is needed, and only the groups that
        // lost a member are re-split.
        grouping.removePhotos(identifiers)
        publishGroups()
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
            // next notification diffs correctly. Do this before any await, so a
            // notification arriving meanwhile doesn't re-diff this change.
            self.fetchResult = details.fetchResultAfterChanges
            // Cached feature prints are kept across scans, so drop the ones for
            // photos that were edited or removed. If the change can't be
            // diffed, drop them all.
            if details.hasIncrementalChanges {
                let stale = Set((details.changedObjects + details.removedObjects).map(\.localIdentifier))
                await self.analyzer.invalidate(stale)
            } else {
                await self.analyzer.clearCache()
            }
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
        resetScanCursor()   // sortedPhotos was rebuilt

        // Drop pairs referencing removed photos. (Deletion only removes edges.)
        if !removed.isEmpty {
            removePairs { removed.contains($0.first) || removed.contains($0.second) }
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
            // Photos added BEYOND the scanned frontier (e.g. everything new when
            // nothing was scanned yet) sit in the unscanned tail. Resume so the
            // buffer fills instead of stranding `hasMoreToScan` with no running
            // task — the home-row spinner that persisted after adding photos via
            // the limited-library picker.
            resumeIfNeeded()
            return
        }

        let token = UUID()
        revision = token
        // Don't clear `hasScanned` here: if a window change supersedes this
        // reconcile it returns early, which used to leave the flag false.
        isScanning = true

        let addedSet = Set(addedInsideWindow)
        // These added photos sit in the already-scanned region and are being
        // measured now, so they join the scanned set and progression. Their
        // displayed group position is governed by the earliest existing member
        // of whatever component they join, so appending here is fine.
        scannedIDs.formUnion(addedSet)
        advanceScanCursor()
        for id in addedInsideWindow where !scanProgression.contains(id) { scanProgression.append(id) }
        // Resync the grouping with the reconciled library (removed photos and
        // pairs, newly scanned photos) before streaming the new measurements
        // into it incrementally.
        applyThreshold()
        let anchorIndices = sortedPhotos.indices.filter { addedSet.contains(sortedPhotos[$0].id) }
        var neighborhoods: [CandidateNeighborhood] = []
        for anchorIndex in anchorIndices {
            neighborhoods += SequenceGrouping.neighborhoods(in: sortedPhotos, anchorRange: anchorIndex..<(anchorIndex + 1))
        }
        let missingComparisons = geoFilteredComparisons(for: neighborhoods)
            .filter { !measuredComparisons.contains($0) }
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
                    self.appendMeasuredPairs(newPairs)
                    self.publishGroupsThrottled()
                }
            )
            guard revision == token else { return }
            appendMeasuredPairs(scores.pairs)
            unavailablePhotoIDs.formUnion(scores.unavailableIDs.filter { photosByID[$0] != nil })
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
