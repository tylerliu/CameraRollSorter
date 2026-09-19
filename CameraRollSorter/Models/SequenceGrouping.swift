import Foundation

struct TimedPhoto: Identifiable, Sendable {
    let id: String
    let date: Date
    // Optional capture coordinate, used for geo-proximity gating. Stored as raw
    // doubles to keep this model free of CoreLocation and easily testable.
    var latitude: Double?
    var longitude: Double?

    init(id: String, date: Date, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }
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

    /// Drops comparisons whose two photos are known to be far apart, so Vision
    /// never runs on them. A pair is dropped ONLY when BOTH photos have a
    /// coordinate and their great-circle distance exceeds `maxMeters`. If either
    /// photo lacks a coordinate we can't rule it out, so it is kept (we never
    /// skip a pair we're unsure about).
    static func geoFiltered(
        _ comparisons: [CandidateComparison],
        photos: [TimedPhoto],
        maxMeters: Double
    ) -> [CandidateComparison] {
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        return comparisons.filter { pair in
            guard let a = byID[pair.first], let b = byID[pair.second],
                  let aLat = a.latitude, let aLon = a.longitude,
                  let bLat = b.latitude, let bLon = b.longitude else {
                return true // missing coordinate on either side → keep
            }
            return greatCircleMeters(aLat, aLon, bLat, bLon) <= maxMeters
        }
    }

    /// Great-circle (haversine) distance in meters between two lat/lon points.
    static func greatCircleMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let earthRadius = 6_371_000.0 // meters
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}
