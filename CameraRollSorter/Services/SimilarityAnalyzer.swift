import Photos
import Vision

struct SimilarityResult: Sendable {
    let pairs: [SimilarityPair]
    let unavailableIDs: Set<String>
}

// Serial background actor keeps Vision work off the UI and bounds image memory.
actor SimilarityAnalyzer {
    /// One anchor's share of a batch: the comparisons that complete it. The
    /// anchor is done once these are measured (comparisons with earlier
    /// anchors in the same batch belong to those anchors).
    struct AnchorWork: Sendable {
        let anchor: String
        let comparisons: [CandidateComparison]
    }

    // Feature prints kept ACROSS calls, so neighbors shared by consecutive
    // batches aren't decoded and run through Vision twice. Bounded and
    // evicted oldest-first: scans walk the timeline in order, so recent prints
    // are the ones neighbors need. Invalidate when a photo's content changes.
    private var cache: [String: VNFeaturePrintObservation] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 256
    // How often to report progress to the main actor. Bounds both callback
    // traffic and how long a finished anchor waits to show up.
    private let progressInterval: Duration = .milliseconds(50)

    /// Drop cached prints for photos that were edited or removed.
    func invalidate(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { cache[id] = nil }
        cacheOrder.removeAll { ids.contains($0) }
    }

    /// Drop every cached print (e.g. when a library change can't be diffed).
    func clearCache() {
        cache = [:]
        cacheOrder = []
    }

    private func featurePrint(_ identifier: String) throws -> VNFeaturePrintObservation? {
        return try autoreleasepool {
                guard let loaded = PhotoImageLoading.synchronousImage(for: identifier, targetSize: 512) else { return nil }
                // Normalize orientation without cropping (on iOS this is the
                // same UIGraphicsImageRenderer pass as before; see PlatformImage).
                guard let cgImage = loaded.orientationNormalizedCGImage else { return nil }
                return try FeaturePrintGenerator.observation(for: cgImage)
            }
    }

    /// Cached print for `id`, computing it on a miss. `unavailable` is per call
    /// (photos not available locally are retried on later calls).
    private func load(_ id: String, unavailable: inout Set<String>) throws -> VNFeaturePrintObservation? {
        if let cached = cache[id] { return cached }
        if unavailable.contains(id) { return nil }
        guard let value = try featurePrint(id) else { unavailable.insert(id); return nil }
        if cacheOrder.count >= cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        cache[id] = value
        cacheOrder.append(id)
        return value
    }

    /// Measure anchors in order, reporting finished anchors (and their pairs)
    /// as they complete, at most every `progressInterval`. `progress` returns
    /// false to stop early (e.g. the list's buffer is full); the remaining
    /// anchors are left unmeasured and unreported.
    func analyze(
        _ work: [AnchorWork],
        progress: @escaping @MainActor @Sendable (_ pairs: [SimilarityPair], _ completedAnchors: [String]) -> Bool
    ) async throws -> SimilarityResult {
        var unavailable: Set<String> = []
        var pairs: [SimilarityPair] = []
        var pendingPairs: [SimilarityPair] = []
        var pendingAnchors: [String] = []
        let clock = ContinuousClock()
        var lastReport = clock.now
        for (index, item) in work.enumerated() {
            for edge in item.comparisons {
                try Task.checkCancellation()
                let first = try load(edge.first, unavailable: &unavailable)
                let second = try load(edge.second, unavailable: &unavailable)
                if let first, let second {
                    var distance: Float = 0
                    try first.computeDistance(&distance, to: second)
                    let pair = SimilarityPair(first: edge.first, second: edge.second, distance: distance)
                    pairs.append(pair)
                    pendingPairs.append(pair)
                }
            }
            pendingAnchors.append(item.anchor)
            let isLast = index == work.count - 1
            if isLast || clock.now - lastReport >= progressInterval {
                let keepGoing = await progress(pendingPairs, pendingAnchors)
                pendingPairs.removeAll(keepingCapacity: true)
                pendingAnchors.removeAll(keepingCapacity: true)
                lastReport = clock.now
                if !keepGoing { break }
            }
        }
        return SimilarityResult(pairs: pairs, unavailableIDs: unavailable)
    }

    /// Measure a flat list of comparisons with no anchor tracking (used by
    /// library reconcile). Streams pairs through `partialResults`.
    func analyzeComparisons(
        _ comparisons: [CandidateComparison],
        partialResults: @escaping @MainActor @Sendable ([SimilarityPair]) -> Void
    ) async throws -> SimilarityResult {
        // One comparison per "anchor" so progress still streams during a long list.
        let work = comparisons.map { AnchorWork(anchor: "", comparisons: [$0]) }
        return try await analyze(work) { pairs, _ in
            if !pairs.isEmpty { partialResults(pairs) }
            return true
        }
    }
}
