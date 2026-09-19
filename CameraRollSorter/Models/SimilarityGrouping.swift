import Foundation

struct SimilarityPair: Identifiable, Sendable {
    var id: String { first + ":" + second }
    let first: String
    let second: String
    let distance: Float
}

nonisolated enum SimilarityGrouping {
    // Connected components of accepted candidate edges. Five limits the search,
    // not the resulting component size. Endpoints need not directly match.
    static func groups(photos: [TimedPhoto], pairs: [SimilarityPair], threshold: Float) -> [PhotoSequence] {
        let ordered = photos.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        let indices = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        var parents = Array(ordered.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current {
                parents[current] = parents[parents[current]]
                current = parents[current]
            }
            return current
        }
        for pair in pairs where pair.distance.isFinite && pair.distance >= 0 && pair.distance <= threshold {
            guard let first = indices[pair.first], let second = indices[pair.second] else { continue }
            let a = root(first), b = root(second)
            if a != b { parents[max(a, b)] = min(a, b) }
        }
        var components: [Int: [TimedPhoto]] = [:]
        for index in ordered.indices { components[root(index), default: []].append(ordered[index]) }
        return components.keys.sorted().compactMap { key in
            guard let members = components[key], members.count > 1 else { return nil }
            return PhotoSequence(photos: members)
        }
    }
    // Kruskal over measured, qualifying candidate edges only. No new image
    // comparisons and no assumed edges between untested pairs.
    static func minimumSpanningTree(photos: [TimedPhoto], pairs: [SimilarityPair], threshold: Float) -> [SimilarityPair] {
        let ids = photos.map(\.id).sorted()
        let indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        var parents = Array(ids.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current {
                parents[current] = parents[parents[current]]
                current = parents[current]
            }
            return current
        }
        let edges = pairs.filter { $0.distance.isFinite && $0.distance >= 0 && $0.distance <= threshold }
            .map { pair in
                SimilarityPair(first: min(pair.first, pair.second), second: max(pair.first, pair.second), distance: pair.distance)
            }.sorted {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                if $0.first != $1.first { return $0.first < $1.first }
                return $0.second < $1.second
            }
        var tree: [SimilarityPair] = []
        for edge in edges {
            guard let first = indices[edge.first], let second = indices[edge.second] else { continue }
            let a = root(first), b = root(second)
            guard a != b else { continue }
            parents[max(a, b)] = min(a, b)
            tree.append(edge)
            if tree.count == max(0, photos.count - 1) { break }
        }
        return tree
    }

    // MARK: - Similarity ordering (flicker-comparison layout)

    /// Orders a group's photos so the most-similar shots sit adjacent, turning
    /// filmstrip scrubbing into blink/flicker comparison.
    ///
    /// Strategy (spine + insertion):
    /// 1. Build the MST over measured edges.
    /// 2. Extract the weighted-diameter path (the "spine") — the longest run of
    ///    genuinely-connected photos, which has no jumps.
    /// 3. Insert each off-spine photo immediately beside its MST attachment on
    ///    the spine, on whichever side is more similar.
    ///
    /// Photos not connected by any measured edge (isolated in the MST) are
    /// appended at the end in deterministic id order. Falls back to the input
    /// order when there are no edges.
    static func similarityOrder(photos: [TimedPhoto], pairs: [SimilarityPair], threshold: Float) -> [TimedPhoto] {
        guard photos.count > 2 else { return photos }
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let tree = minimumSpanningTree(photos: photos, pairs: pairs, threshold: threshold)
        guard !tree.isEmpty else { return photos }

        // Adjacency list from the MST (undirected, with edge weights).
        var adjacency: [String: [(neighbor: String, distance: Float)]] = [:]
        for edge in tree {
            adjacency[edge.first, default: []].append((edge.second, edge.distance))
            adjacency[edge.second, default: []].append((edge.first, edge.distance))
        }
        // Deterministic neighbor iteration: closest first, then id.
        for key in adjacency.keys {
            adjacency[key]?.sort {
                $0.distance == $1.distance ? $0.neighbor < $1.neighbor : $0.distance < $1.distance
            }
        }

        // --- Weighted farthest-node search from a start, returning the path. ---
        func farthest(from start: String) -> (node: String, distance: Float, parent: [String: String]) {
            var visited: Set<String> = [start]
            var parent: [String: String] = [:]
            var best = start
            var bestDistance: Float = 0
            // DFS stack carrying accumulated distance.
            var stack: [(node: String, distance: Float)] = [(start, 0)]
            while let (node, dist) = stack.popLast() {
                if dist > bestDistance || (dist == bestDistance && node < best) {
                    bestDistance = dist
                    best = node
                }
                for (neighbor, weight) in adjacency[node] ?? [] where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    parent[neighbor] = node
                    stack.append((neighbor, dist + weight))
                }
            }
            return (best, bestDistance, parent)
        }

        // Two passes: any node → one diameter end → the other diameter end.
        // Start deterministically from the smallest id present in the tree.
        let treeNodes = Set(tree.flatMap { [$0.first, $0.second] })
        let seed = treeNodes.min()!
        let end1 = farthest(from: seed).node
        let (end2, _, parent2) = farthest(from: end1)

        // Reconstruct the spine path end2 → end1 via parent pointers.
        var spine: [String] = []
        var cursor: String? = end2
        while let c = cursor {
            spine.append(c)
            cursor = parent2[c]
        }
        // spine now runs end2 ... end1.

        // --- Insert off-spine nodes via cheapest-gap insertion. ---
        // For each off-spine node X and each adjacent pair (A,B) in the current
        // order, the insertion cost is the increase in total adjacency distance:
        //     dist(A,X) + dist(X,B) − dist(A,B)
        // We place X in the minimum-cost gap. Unmeasured pairs are treated as
        // +infinity, so a node lands next to something it actually matched.
        var order = spine
        let spineSet = Set(spine)
        // Insert nearer-to-spine nodes first (tightest MST attachment edge), so
        // the strongest links settle before weaker ones. Tie-break by id.
        func attachmentDistance(_ node: String) -> Float {
            adjacency[node]?.first?.distance ?? .infinity
        }
        let offSpine = treeNodes.subtracting(spineSet).sorted {
            let da = attachmentDistance($0), db = attachmentDistance($1)
            return da == db ? $0 < $1 : da < db
        }
        for node in offSpine {
            let insertIndex = cheapestInsertionIndex(for: node, in: order, pairs: pairs)
            order.insert(node, at: insertIndex)
        }

        // Append any photos with no measured edges at all (isolated), by id.
        let placed = Set(order)
        let isolated = photos.map(\.id).filter { !placed.contains($0) }.sorted()
        order.append(contentsOf: isolated)

        return order.compactMap { byID[$0] }
    }

    /// Greedy insertion that minimizes the added dissimilarity when placing
    /// `node` into a gap of the current order.
    ///
    /// The primary key is the node's *closest* measured neighbor across the two
    /// sides of the gap (`min(d(left), d(right))`) — this guarantees the node
    /// lands adjacent to whatever it actually matched, even when its other side
    /// is unmeasured. The secondary key is the sum of both new adjacency edges
    /// (a proper cheapest-insertion tie-break for nodes measured to both sides).
    /// Deterministic: further ties resolve to the earliest gap.
    private static func cheapestInsertionIndex(
        for node: String, in order: [String], pairs: [SimilarityPair]
    ) -> Int {
        // Measured distance from `node` to any other id; unmeasured → +infinity.
        var lookup: [String: Float] = [:]
        for p in pairs where p.distance.isFinite && p.distance >= 0 {
            if p.first == node { lookup[p.second] = min(lookup[p.second] ?? .infinity, p.distance) }
            if p.second == node { lookup[p.first] = min(lookup[p.first] ?? .infinity, p.distance) }
        }
        func d(_ other: String) -> Float { lookup[other] ?? .infinity }

        var bestIndex = order.count
        var bestPrimary = Float.infinity   // closest new neighbor
        var bestSecondary = Float.infinity // sum of new neighbor edges

        for index in 0...order.count {
            let left = index - 1 >= 0 ? d(order[index - 1]) : .infinity
            let right = index < order.count ? d(order[index]) : .infinity
            let primary = min(left, right)
            // Sum of finite new edges only (an infinite side adds nothing to the
            // path cost — the node simply has one neighbor there).
            let secondary = (left.isFinite ? left : 0) + (right.isFinite ? right : 0)

            if primary < bestPrimary
                || (primary == bestPrimary && secondary < bestSecondary) {
                bestPrimary = primary
                bestSecondary = secondary
                bestIndex = index
            }
        }
        return bestIndex
    }
}
