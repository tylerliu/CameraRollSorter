import Photos
import UIKit
import Vision

struct SimilarityResult: Sendable {
    let pairs: [SimilarityPair]
    let unavailableIDs: Set<String>
}

// Serial background actor keeps Vision work off the UI and bounds image memory.
actor SimilarityAnalyzer {
    private func featurePrint(_ identifier: String) throws -> VNFeaturePrintObservation? {
        return try autoreleasepool {
                guard let loaded = PhotoImageLoading.synchronousImage(for: identifier, targetSize: 512) else { return nil }
                // Render once to normalize UIImage orientation without cropping.
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let normalized = UIGraphicsImageRenderer(size: loaded.size, format: format).image { _ in
                    loaded.draw(in: CGRect(origin: .zero, size: loaded.size))
                }
                guard let cgImage = normalized.cgImage else { return nil }
                return try FeaturePrintGenerator.observation(for: cgImage)
            }
    }

    func analyzeCandidates(
        _ candidates: [CandidateNeighborhood],
        progress: @escaping @MainActor @Sendable (Int, Int) -> Void,
        partialResults: @escaping @MainActor @Sendable ([SimilarityPair]) -> Void
    ) async throws -> SimilarityResult {
        try await analyzeComparisons(SequenceGrouping.comparisons(candidates), progress: progress, partialResults: partialResults)
    }

    func analyzeComparisons(
        _ comparisons: [CandidateComparison],
        progress: @escaping @MainActor @Sendable (Int, Int) -> Void,
        partialResults: @escaping @MainActor @Sendable ([SimilarityPair]) -> Void
    ) async throws -> SimilarityResult {
        // A bounded per-scan cache avoids retaining a whole library of feature prints.
        var cache: [String: VNFeaturePrintObservation] = [:]
        var cacheOrder: [String] = []
        var unavailable: Set<String> = []
        func load(_ id: String) throws -> VNFeaturePrintObservation? {
            if let cached = cache[id] { return cached }
            if unavailable.contains(id) { return nil }
            guard let value = try featurePrint(id) else { unavailable.insert(id); return nil }
            if cacheOrder.count >= 256 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
            cache[id] = value
            cacheOrder.append(id)
            return value
        }
        var pairs: [SimilarityPair] = []
        var pendingPairs: [SimilarityPair] = []
        let partialResultsBatchSize = 5 // Delivery cadence only; groups have no size limit.
        await progress(0, comparisons.count)
        for (index, edge) in comparisons.enumerated() {
            try Task.checkCancellation()
            let first = try load(edge.first)
            let second = try load(edge.second)
            if let first, let second {
                var distance: Float = 0
                try first.computeDistance(&distance, to: second)
                let pair = SimilarityPair(first: edge.first, second: edge.second, distance: distance)
                pairs.append(pair)
                pendingPairs.append(pair)
                // Keep the UI responsive while avoiding a main-actor callback for every edge.
                if pendingPairs.count >= partialResultsBatchSize {
                    await partialResults(pendingPairs)
                    pendingPairs.removeAll(keepingCapacity: true)
                }
            }
            if index % 10 == 0 || index + 1 == comparisons.count { await progress(index + 1, comparisons.count) }
        }
        if !pendingPairs.isEmpty { await partialResults(pendingPairs) }
        return SimilarityResult(pairs: pairs, unavailableIDs: unavailable)
    }
}
