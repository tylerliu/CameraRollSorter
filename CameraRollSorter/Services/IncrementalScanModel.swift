import Foundation
import Observation
import Photos

/// An item produced by an incremental scan: identified by its
/// `PHAsset.localIdentifier`.
protocol ScanItem: Identifiable where ID == String {}

/// Shared scan engine for the per-screen cleanup flows (Live → Still,
/// Low-aesthetic). Candidates are fetched fast (metadata only), ordered and
/// windowed with `SequenceGrouping.scanOrdered`, then classified in buffered
/// batches so a large library streams in rather than blocking: the grid shows
/// results as they arrive and keeps a rolling buffer ahead of the scroll
/// position.
///
/// Subclasses supply the two feature-specific steps by overriding
/// `fetchCandidates()` and `classify(_:)`.
@MainActor @Observable
class IncrementalScanModel<Item: ScanItem> {
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var items: [Item] = []
    var isScanning = false
    var hasScanned = false
    var errorMessage: String?
    // Remembers the top-visible grid item so scroll position is restored when
    // navigating away and back within a session. Not persisted across launches.
    var scrollAnchorID: String?

    // Per-view scan-window state, bound to the pinned ScanControlsHeader. NOT
    // shared with the other cleanup screens — each list has its own window,
    // persisted under its own key prefix so it survives app relaunch.
    var scanDirectionRaw = "newer" { didSet { windowStore.direction = scanDirectionRaw } }
    var scanStartEnabled = false { didSet { windowStore.startEnabled = scanStartEnabled } }
    var scanStartInterval = 0.0 { didSet { windowStore.startInterval = scanStartInterval } }

    @ObservationIgnored private let windowStore: ScanWindowStore
    @ObservationIgnored private let batchSize: Int
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var changeRelay: PhotoLibraryChangeRelay?
    // True while `scan()` is fetching the candidate set. Window changes wait
    // for it instead of cancelling it.
    @ObservationIgnored private var fetchingCandidates = false

    private var allCandidates: [TimedPhoto] = [] // full fetched candidate set (unwindowed)
    private var candidates: [TimedPhoto] = []    // ordered+windowed candidates
    private var classifiedCount = 0              // how far along `candidates` we've classified
    // Bottom-most grid row currently on screen; the scan keeps
    // `ScanBuffer.target` items classified ahead of it, and pauses after the
    // batch in flight when the viewer scrolls back up.
    @ObservationIgnored private var scanAheadOf = 0
    @ObservationIgnored private var lastScanDirection: ScanDirection = .newer
    @ObservationIgnored private var lastScanStartDate: Date?
    // True while the grid is on screen. Off → only the small preview buffer is
    // filled (home screen); on → the full buffer.
    @ObservationIgnored private var listActive = false
    // True while another cleanup feature's screen is open, so this scan
    // doesn't compete with it. Set by the home screen.
    @ObservationIgnored private var isPaused = false

    init(windowPrefix: String, batchSize: Int) {
        windowStore = ScanWindowStore(prefix: windowPrefix)
        self.batchSize = batchSize
        // Restore the persisted scan window (didSet writes back the same values).
        scanDirectionRaw = windowStore.direction
        scanStartEnabled = windowStore.startEnabled
        scanStartInterval = windowStore.startInterval
    }

    // MARK: - Subclass hooks

    /// Fast metadata-only fetch of every candidate (id + date).
    func fetchCandidates() async -> [TimedPhoto] {
        fatalError("Subclasses must override fetchCandidates()")
    }

    /// Classify a batch, returning only the matching items.
    func classify(_ batch: [TimedPhoto]) async -> [Item] {
        fatalError("Subclasses must override classify(_:)")
    }

    // MARK: - State

    var canRead: Bool { authorization == .authorized || authorization == .limited }

    /// True while there are still unclassified candidates in the window.
    var hasMoreToScan: Bool { classifiedCount < candidates.count }

    /// Capture-date span of all candidates, to bound/seed the start-date
    /// picker. nil before the first scan or when there are none.
    var libraryDateRange: ClosedRange<Date>? {
        guard let min = allCandidates.map(\.date).min(),
              let max = allCandidates.map(\.date).max() else { return nil }
        return min...max
    }

    private var scanDirectionSetting: ScanDirection {
        ScanDirection(rawValue: scanDirectionRaw) ?? .older
    }

    private var scanStartDateSetting: Date? {
        guard scanStartEnabled, scanStartInterval > 0 else { return nil }
        return Date(timeIntervalSince1970: scanStartInterval)
    }

    /// True when classification should stop: paused, or enough items buffered
    /// ahead of the viewer.
    private var bufferFull: Bool {
        isPaused || items.count - scanAheadOf >= ScanBuffer.effectiveTarget(listActive: listActive)
    }

    // MARK: - Scan lifecycle

    /// Fresh scan: fetch the candidate set, window it, then classify in
    /// buffered batches.
    func scan() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else {
            items = []
            hasScanned = false
            return
        }
        if changeRelay == nil {
            // PhotoKit calls back on a background thread; reconcile on the main
            // actor incrementally rather than resetting the grid.
            changeRelay = PhotoLibraryChangeRelay { [weak self] in
                Task { @MainActor in await self?.syncLibrary() }
            }
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
        fetchingCandidates = true
        scanTask = Task {
            let found = await fetchCandidates()
            guard !Task.isCancelled else { return }
            allCandidates = found
            // Window with the settings as of NOW: a window change made during
            // the fetch is deferred to here (see `applyScanSettings`).
            lastScanDirection = scanDirectionSetting
            lastScanStartDate = scanStartDateSetting
            candidates = SequenceGrouping.scanOrdered(
                found, direction: lastScanDirection, startDate: lastScanStartDate
            )
            fetchingCandidates = false
            hasScanned = true
            await classifyBatches()
            // A cancelled task must not clear the flag for the scan that
            // replaced it.
            if !Task.isCancelled { isScanning = false }
        }
    }

    /// Classify more as the grid scrolls. `currentIndex` is the bottom-most
    /// visible row (or the item count when the grid's end is visible); it can
    /// move either way.
    func scanMore(currentIndex: Int) {
        scanAheadOf = currentIndex
        resumeIfNeeded()
    }

    /// Called when the grid appears/disappears. Opening it lifts the buffer from
    /// the home-screen preview cap to the full one, resuming classification.
    func setListActive(_ active: Bool) {
        listActive = active
        if active { resumeIfNeeded() }
    }

    /// Pause (after the batch in flight) or resume this scan.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused { resumeIfNeeded() }
    }

    /// Called when the direction/start-date controls change. Re-windows from
    /// the FULL fetched candidate set (so widening brings items back) and
    /// rebuilds the grid from the front.
    func applyScanSettings() {
        // While the initial fetch is running there's nothing to re-window, and
        // cancelling it would leave the list empty. The fetch picks up the
        // current settings when it lands.
        guard !fetchingCandidates else { return }
        let newDirection = scanDirectionSetting
        let newStart = scanStartDateSetting
        guard newDirection != lastScanDirection || newStart != lastScanStartDate else { return }
        lastScanDirection = newDirection
        lastScanStartDate = newStart
        candidates = SequenceGrouping.scanOrdered(
            allCandidates, direction: newDirection, startDate: newStart
        )
        scrollAnchorID = nil
        restartClassification()
    }

    /// Clear results and classify the current window again from the front.
    func restartClassification() {
        scanTask?.cancel()
        items = []
        classifiedCount = 0
        scanAheadOf = 0
        isScanning = true
        scanTask = Task {
            await classifyBatches()
            if !Task.isCancelled { isScanning = false }
        }
    }

    /// Stop the batch loop without touching results.
    func cancelClassification() {
        scanTask?.cancel()
        isScanning = false
    }

    /// Start classifying if the buffer ahead of the viewer isn't full and
    /// nothing is running.
    private func resumeIfNeeded() {
        guard canRead, hasMoreToScan, !isScanning, !bufferFull else { return }
        isScanning = true
        scanTask = Task {
            await classifyBatches()
            if !Task.isCancelled { isScanning = false }
        }
    }

    /// Classify successive `batchSize` slices of `candidates`, appending matches
    /// to `items` in window order. Stops when the window is exhausted or the
    /// buffer ahead of the viewer is full. Yields between batches.
    private func classifyBatches() async {
        while hasMoreToScan {
            if Task.isCancelled { return }
            if bufferFull { break }

            let start = classifiedCount
            let end = min(start + batchSize, candidates.count)
            let batch = Array(candidates[start..<end])
            let matches = await classify(batch)
            if Task.isCancelled { return }
            let byID = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Never let a duplicate id reach `items` (the grid's ForEach ids
            // must be unique).
            var shownIDs = Set(items.map(\.id))
            for candidate in batch {
                if let item = byID[candidate.id], shownIDs.insert(candidate.id).inserted {
                    items.append(item)
                }
            }
            classifiedCount = end
            await Task.yield()
        }
    }

    // MARK: - Library changes

    /// Drop ids from every result surface after a deletion/conversion so the
    /// grid and candidate sets stay consistent.
    func removeFromCurrentResults(_ identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        items.removeAll { identifiers.contains($0.id) }
        candidates.removeAll { identifiers.contains($0.id) }
        allCandidates.removeAll { identifiers.contains($0.id) }
        classifiedCount = min(classifiedCount, candidates.count)
    }

    /// Incrementally reconcile the grid with the current library — used on
    /// library changes and scene activation — WITHOUT resetting scroll:
    /// - removed candidates drop out of `items`
    /// - added candidates inside the classified window are classified now and
    ///   inserted in window order; ones beyond it stay in the unclassified tail
    ///   for `scanMore`.
    func syncLibrary() async {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else { items = []; hasScanned = false; return }
        // If we never scanned, a plain scan is correct (nothing to preserve).
        guard hasScanned, !isScanning else { if !hasScanned { scan() }; return }

        let found = await fetchCandidates()
        let oldIDs = Set(allCandidates.map(\.id))
        let newIDs = Set(found.map(\.id))
        let added = newIDs.subtracting(oldIDs)
        let removed = oldIDs.subtracting(newIDs)
        guard !added.isEmpty || !removed.isEmpty else { return }

        allCandidates = found
        if !removed.isEmpty {
            items.removeAll { removed.contains($0.id) }
        }

        // Re-window from the fresh set; the classified frontier is the furthest
        // candidate already shown.
        let shownIDs = Set(items.map(\.id))
        candidates = SequenceGrouping.scanOrdered(
            found, direction: scanDirectionSetting, startDate: scanStartDateSetting
        )
        let frontier = candidates.lastIndex { shownIDs.contains($0.id) }
        classifiedCount = (frontier ?? -1) + 1

        let addedInside = candidates.prefix(classifiedCount).filter { added.contains($0.id) }
        guard !addedInside.isEmpty else { return }
        let newItems = await classify(Array(addedInside))
        let itemByID = Dictionary((items + newItems).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Rebuild in window order so new matches land in position, not at the end.
        items = candidates.prefix(classifiedCount).compactMap { itemByID[$0.id] }
    }
}

/// Non-generic PhotoKit change observer (a generic class can't conform to the
/// Objective-C protocol). Registers on init, unregisters on deinit, and calls
/// `onChange` on PhotoKit's background thread.
nonisolated final class PhotoLibraryChangeRelay: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}
