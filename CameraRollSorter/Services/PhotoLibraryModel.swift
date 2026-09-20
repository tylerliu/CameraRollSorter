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
    private let batchSize = 256                 // anchors processed per incremental step
    // Soft stop for the initial scan: pause once this many groups exist. User
    // configurable in review settings (default 200).
    private var targetGroupCount: Int {
        let value = UserDefaults.standard.object(forKey: "review.initialGroupTarget") as? Int ?? 200
        return max(1, value)
    }
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
        scannedIDs = []
        scanProgression = []
        isScanning = true
        scanTask = Task {
            let result = await scanner.scan()
            guard !Task.isCancelled else { return }
            photos = result.photos
            fetchResult = result.fetchResult
            sortedPhotos = SequenceGrouping.scanOrdered(
                result.photos,
                direction: Self.scanDirectionSetting,
                startDate: Self.scanStartDateSetting
            )
            scannedIDs = []
            scanProgression = []
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
            // filling as the user scrolls beyond the initial group target.
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
            let batchComparisons = geoFilteredComparisons(for: neighborhoods)
            let batchAnchorIDs = Set(batchAnchorIndices.map { sortedPhotos[$0].id })

            isScanningBatch = true
            let done = scannedIDs.count + batchAnchorIDs.count
            progress = "Comparing photos… \(done) of \(sortedPhotos.count)"
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

            // Record scan-progression order (skip any already recorded). Iterate
            // sortedPhotos so within-batch order follows the scan traversal.
            for index in batchAnchorIndices {
                let id = sortedPhotos[index].id
                if !scannedIDs.contains(id) { scanProgression.append(id) }
            }
            scannedIDs.formUnion(batchAnchorIDs)
            updateSummary()
            applyThreshold()
        }
        isScanningBatch = false
        progress = hasMoreToScan ? "Paused — scroll for more" : "Scan complete"
    }

    func applyThreshold() {
        threshold = Float(UserDefaults.standard.object(forKey: "review.distanceThreshold") as? Double ?? 0.4)
        // Group in *scan-progression* order so newly scanned groups append to
        // the back of the list and a direction flip reverses the visible list.
        // Only scanned photos can form groups (unscanned ones have no measured
        // pairs), so grouping over the progression is complete.
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var ordered: [TimedPhoto] = []
        for id in scanProgression where seen.insert(id).inserted {
            if let photo = byID[id] { ordered.append(photo) }
        }
        // Include pair endpoints that were pulled in as neighbors but weren't
        // themselves anchors, so a group never drops a member. They attach to
        // their component, whose position is governed by its earliest anchor.
        for pair in pairs {
            for id in [pair.first, pair.second] where seen.insert(id).inserted {
                if let photo = byID[id] { ordered.append(photo) }
            }
        }
        groups = SimilarityGrouping.groups(photos: ordered, pairs: pairs, threshold: threshold)
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

    /// Snapshot the geo-gate and scan-order config used by the current scan, so
    /// `applySettings` can tell whether (and how) a change needs reconciling.
    private func recordGeoConfig() {
        lastScanGeoEnabled = Self.geoGateEnabledSetting
        lastScanGeoKilometers = Self.geoGateKilometersSetting
        lastScanDirection = Self.scanDirectionSetting
        lastScanStartDate = Self.scanStartDateSetting
    }

    private static var geoGateEnabledSetting: Bool {
        UserDefaults.standard.object(forKey: "review.geoGateEnabled") as? Bool ?? true
    }
    private static var geoGateKilometersSetting: Double {
        UserDefaults.standard.object(forKey: "review.geoGateKilometers") as? Double ?? 1.0
    }
    private static var scanDirectionSetting: ScanDirection {
        let raw = UserDefaults.standard.string(forKey: "review.scanDirection") ?? "older"
        return ScanDirection(rawValue: raw) ?? .older
    }
    /// The configured scan start date, or nil when the "start from a date"
    /// toggle is off (scan the whole roll).
    private static var scanStartDateSetting: Date? {
        guard UserDefaults.standard.bool(forKey: "review.scanStartEnabled") else { return nil }
        let interval = UserDefaults.standard.double(forKey: "review.scanStartDate")
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
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

        let newDirection = Self.scanDirectionSetting
        let newStart = Self.scanStartDateSetting

        // Scan-scope change (direction and/or start date). Two-phase so rapid
        // adjustments don't churn results:
        //   • Immediately: apply the additive part — reorder to the new
        //     direction and start scanning any newly-in-window photos — while
        //     KEEPING currently-shown results visible (nothing dropped yet).
        //   • After 2s of no further change: prune everything now out-of-window.
        // Because reconciliation is set-based, retained pairs are reused for
        // free if a later change brings their photos back in-window.
        if newDirection != lastScanDirection || newStart != lastScanStartDate,
           hasScanned || isScanning {
            expandScanWindow(direction: newDirection, startDate: newStart,
                             flipped: newDirection != lastScanDirection)
            scheduleWindowPrune(direction: newDirection, startDate: newStart)
        }

        lastScanDirection = newDirection
        lastScanStartDate = newStart

        // Threshold change only regroups existing scores.
        applyThreshold()
        // Resume scanning if there are unscanned photos and we're below the cap.
        if hasMoreToScan, groups.count < targetGroupCount, !isScanning {
            isScanning = true
            scanTask = Task {
                await runBatches(untilGroupCap: true)
                isScanning = false
            }
        }
    }

    /// Additive phase of a window change: rebuild the traversal order to the new
    /// window UNION the photos currently shown, so new results populate while
    /// existing ones stay visible. Nothing is dropped here — the prune (which
    /// removes out-of-window results) is deferred by `scheduleWindowPrune`.
    private func expandScanWindow(direction: ScanDirection, startDate: Date?, flipped: Bool) {
        let window = SequenceGrouping.scanOrdered(photos, direction: direction, startDate: startDate)
        let windowIDs = Set(window.map(\.id))
        // Currently-shown photos to keep visible during the grace period: any
        // scanned photo (in progression) not already in the new window.
        let extraIDs = Set(scanProgression).subtracting(windowIDs)
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let extras = SequenceGrouping.scanOrdered(
            extraIDs.compactMap { byID[$0] }, direction: direction, startDate: nil
        )
        // New window first (front = next to scan), retained extras after.
        sortedPhotos = window + extras
        if flipped { scanProgression.reverse() }
        progress = "Scan window updated"
    }

    /// Debounced destructive prune: 2s after the last scan-scope change, drop
    /// every result whose photo is no longer in the final window. Reruns reset
    /// the timer, so a burst of adjustments prunes once, at the end.
    private func scheduleWindowPrune(direction: ScanDirection, startDate: Date?) {
        windowPruneTask?.cancel()
        windowPruneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.pruneToWindow(direction: direction, startDate: startDate)
        }
    }

    /// Prune all state to exactly the given window. Safe to run late: it only
    /// removes photos that are still out-of-window at prune time.
    private func pruneToWindow(direction: ScanDirection, startDate: Date?) {
        // Only prune if this is still the active window (settings didn't change
        // again to something else after the timer was set).
        guard direction == lastScanDirection, startDate == lastScanStartDate else { return }
        let keep = SequenceGrouping.scanOrdered(photos, direction: direction, startDate: startDate)
        let keepIDs = Set(keep.map(\.id))
        sortedPhotos = keep
        pairs.removeAll { !keepIDs.contains($0.first) || !keepIDs.contains($0.second) }
        scannedIDs.formIntersection(keepIDs)
        scanProgression.removeAll { !keepIDs.contains($0) }
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
        let previousCount = photos.count
        photos.removeAll { identifiers.contains($0.id) }
        let removedDatedPhotos = previousCount - photos.count
        accessiblePhotoCount = max(0, accessiblePhotoCount - removedDatedPhotos)
        pairs.removeAll { identifiers.contains($0.first) || identifiers.contains($0.second) }
        unavailablePhotoIDs.subtract(identifiers)

        // Drop removed photos from the scan set and ordered arrays.
        sortedPhotos.removeAll { identifiers.contains($0.id) }
        scannedIDs.subtract(identifiers)
        scanProgression.removeAll { identifiers.contains($0) }

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

        // Rebuild the scan-ordered array from the new library snapshot, honoring
        // the current direction and start-date window. `scannedIDs` survives the
        // rebuild unchanged — removed IDs are pruned below, added IDs aren't in
        // it yet.
        photos = result.photos
        fetchResult = result.fetchResult
        sortedPhotos = SequenceGrouping.scanOrdered(
            result.photos,
            direction: Self.scanDirectionSetting,
            startDate: Self.scanStartDateSetting
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
