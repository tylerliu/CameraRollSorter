import Foundation

struct TimedPhoto: Identifiable, Sendable {
    let id: String
    let date: Date
}

struct CandidateNeighborhood: Sendable {
    let anchor: TimedPhoto
    var id: String { anchor.id }
    // Internal search neighborhood, never a displayed similarity group.
    let photos: [TimedPhoto]
}

struct PhotoSequence: Identifiable, Sendable {
    var id: String { photos[0].id }
    let photos: [TimedPhoto]
}

nonisolated struct CandidateComparison: Hashable, Sendable {
    let first: String
    let second: String

    init(_ first: String, _ second: String) {
        self.first = min(first, second)
        self.second = max(first, second)
    }
}

nonisolated enum SequenceGrouping {
    // Each photo gets up to five nearest neighbors, strictly less than 24 hours
    // away in either direction. Neighborhoods may overlap; they are not bursts.
    static func groups(_ photos: [TimedPhoto]) -> [CandidateNeighborhood] {
        let sorted = photos.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        var result: [CandidateNeighborhood] = []
        for index in sorted.indices {
            let anchor = sorted[index]
            var left = index - 1
            var right = index + 1
            var neighbors: [Int] = []
            while neighbors.count < 5 {
                let leftGap = left >= 0 ? abs(anchor.date.timeIntervalSince(sorted[left].date)) : .infinity
                let rightGap = right < sorted.count ? abs(anchor.date.timeIntervalSince(sorted[right].date)) : .infinity
                guard min(leftGap, rightGap) < 86_400 else { break }
                if leftGap <= rightGap {
                    neighbors.append(left)
                    left -= 1
                } else {
                    neighbors.append(right)
                    right += 1
                }
            }
            if !neighbors.isEmpty {
                result.append(CandidateNeighborhood(anchor: anchor, photos: (neighbors + [index]).sorted().map { sorted[$0] }))
            }
        }
        return result
    }

    static func comparisons(_ groups: [CandidateNeighborhood]) -> [CandidateComparison] {
        var seen: Set<CandidateComparison> = []
        var result: [CandidateComparison] = []
        for group in groups {
            for photo in group.photos where photo.id != group.anchor.id {
                let comparison = CandidateComparison(group.anchor.id, photo.id)
                if seen.insert(comparison).inserted { result.append(comparison) }
            }
        }
        return result
    }
}
