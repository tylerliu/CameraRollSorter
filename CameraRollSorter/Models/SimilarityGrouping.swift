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
}
