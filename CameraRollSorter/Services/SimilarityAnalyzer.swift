import Photos
import UIKit
import Vision

struct SimilarityResult: Sendable {
    let pairs: [SimilarityPair]
    let unavailable: Int
}

// Serial background actor keeps Vision work off the UI and bounds image memory.
actor SimilarityAnalyzer {
    private func featurePrint(_ identifier: String) throws -> VNFeaturePrintObservation? {
        return try autoreleasepool {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .exact
                options.version = .current
                var loaded: UIImage?
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: options) { image, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true,
                          info?[PHImageErrorKey] == nil,
                          (info?[PHImageCancelledKey] as? Bool) != true else { return }
                    loaded = image
                }
                guard let loaded else { return nil }
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
        struct Edge: Hashable {
            let first: String
            let second: String
        }
        var seen: Set<Edge> = []
        var edges: [Edge] = []
        for candidate in candidates {
            for photo in candidate.photos where photo.id != candidate.anchor.id {
                let ids = [candidate.anchor.id, photo.id].sorted()
                let edge = Edge(first: ids[0], second: ids[1])
                if seen.insert(edge).inserted { edges.append(edge) }
            }
        }
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
        await progress(0, edges.count)
        for (index, edge) in edges.enumerated() {
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
            if index % 10 == 0 || index + 1 == edges.count { await progress(index + 1, edges.count) }
        }
        if !pendingPairs.isEmpty { await partialResults(pendingPairs) }
        return SimilarityResult(pairs: pairs, unavailable: unavailable.count)
    }
}
