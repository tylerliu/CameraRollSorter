import Foundation

func photo(_ id: String, _ seconds: Double) -> TimedPhoto {
    TimedPhoto(id: id, date: Date(timeIntervalSince1970: seconds))
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS: \(message)")
}
func neighbors(_ group: CandidateNeighborhood) -> [String] {
    group.photos.filter { $0.id != group.anchor.id }.map(\.id)
}
check(SequenceGrouping.groups([]).isEmpty, "Empty library")
check(SequenceGrouping.groups([photo("a", 0)]).isEmpty, "Single photo has no candidates")
check(SequenceGrouping.groups([photo("a", 0), photo("b", 86_400)]).isEmpty, "Exactly one day apart is excluded")
check(SequenceGrouping.groups([photo("a", 0), photo("b", 86_399)]).count == 2, "Less than one day apart is included")
let quick = SequenceGrouping.groups((0..<5).map { photo(String($0), Double($0 * 3)) })
check(quick.count == 5 && quick.allSatisfy { $0.photos.count == 5 }, "Five quick shots remain candidates without Vision")
let input = [photo("anchor", 100), photo("a", 99), photo("b", 101), photo("c", 97), photo("d", 104), photo("e", 95), photo("f", 106), photo("distant", 1_000)]
let groups = SequenceGrouping.groups(input.reversed())
let anchor = groups.first { $0.anchor.id == "anchor" }!
check(Set(neighbors(anchor)) == Set(["a", "b", "c", "d", "e"]), "Select the five closest timestamps in either direction")
check(groups.allSatisfy { $0.photos.count <= 6 }, "At most five neighbors plus reference")
check(groups.allSatisfy { group in group.photos.allSatisfy { abs($0.date.timeIntervalSince(group.anchor.date)) < 86_400 } }, "Every comparison is strictly within a day of its reference")
check(anchor.photos.map(\.date) == anchor.photos.map(\.date).sorted(), "Presentation stays chronological")
let old = SequenceGrouping.groups([photo("old1", -100_000_000), photo("old2", -99_999_999)])
check(old.count == 2, "Old photos remain eligible")
let ties = (0..<8).map { photo(String($0), 0) }
let forward = SequenceGrouping.groups(ties).map { neighbors($0) }
let backward = SequenceGrouping.groups(ties.reversed()).map { neighbors($0) }
check(forward == backward, "Equal timestamps have deterministic ordering")
check(SequenceGrouping.groups(ties).allSatisfy { group in Set(group.photos.map(\.id)).count == group.photos.count }, "No self-comparison or duplicate candidate")
let comparisons = SequenceGrouping.comparisons(SequenceGrouping.groups([photo("a", 0), photo("b", 1), photo("c", 2)]))
check(Set(comparisons) == Set([CandidateComparison("a", "b"), CandidateComparison("a", "c"), CandidateComparison("b", "c")]), "Candidate comparisons are canonical and deduplicated")

let chainPhotos = (0..<10).map { photo(String($0), Double($0)) }
let chainPairs = (0..<9).map { SimilarityPair(first: String($0), second: String($0 + 1), distance: 0.4) }
let joined = SimilarityGrouping.groups(photos: chainPhotos, pairs: chainPairs, threshold: 0.5)
check(joined.count == 1 && joined[0].photos.count == 10, "Matching chains form groups larger than five")
check(SimilarityGrouping.groups(photos: chainPhotos, pairs: chainPairs, threshold: 0.3).isEmpty, "Lower threshold removes weak edges")
let splitPairs = chainPairs.map { SimilarityPair(first: $0.first, second: $0.second, distance: $0.first == "4" ? 0.6 : 0.4) }
check(SimilarityGrouping.groups(photos: chainPhotos, pairs: splitPairs, threshold: 0.5).map { $0.photos.count } == [5, 5], "Rejected bridge separates components")
let boundary = [SimilarityPair(first: "0", second: "1", distance: 0.5)]
check(SimilarityGrouping.groups(photos: chainPhotos, pairs: boundary, threshold: 0.5).first?.photos.count == 2, "Threshold includes equal distance and omits isolated photos")
let bad = [SimilarityPair(first: "0", second: "1", distance: .nan), SimilarityPair(first: "2", second: "missing", distance: 0.1)]
check(SimilarityGrouping.groups(photos: chainPhotos, pairs: bad, threshold: 0.5).isEmpty, "Invalid scores and unknown assets do not join groups")
check(Set(SimilarityGrouping.groups(photos: chainPhotos.reversed(), pairs: chainPairs.reversed(), threshold: 0.5).first?.photos.map(\.id) ?? []) == Set(joined.first?.photos.map(\.id) ?? []), "Group membership is stable regardless of input order")
// Groups now follow the caller's photo order (scan order), so members read in
// the order photos were passed in.
check(SimilarityGrouping.groups(photos: chainPhotos, pairs: chainPairs, threshold: 0.5).first?.photos.map(\.id) == chainPhotos.map(\.id), "Group members follow input (scan) order")
check(SimilarityGrouping.groups(photos: chainPhotos.reversed(), pairs: chainPairs, threshold: 0.5).first?.photos.map(\.id) == chainPhotos.reversed().map(\.id), "Reversed input yields reversed member order")

let triangle = [SimilarityPair(first: "0", second: "1", distance: 0.1), SimilarityPair(first: "1", second: "2", distance: 0.2), SimilarityPair(first: "0", second: "2", distance: 0.4)]
let tree = SimilarityGrouping.minimumSpanningTree(photos: Array(chainPhotos.prefix(3)), pairs: triangle, threshold: 0.5)
check(tree.map(\.distance) == [0.1, 0.2], "MST keeps closest connections and drops cycle")
let chainTree = SimilarityGrouping.minimumSpanningTree(photos: chainPhotos, pairs: chainPairs, threshold: 0.5)
check(chainTree.count == 9, "Ten-photo connected group has nine spanning links")
check(SimilarityGrouping.minimumSpanningTree(photos: chainPhotos, pairs: chainPairs, threshold: 0.3).isEmpty, "MST never adds rejected or unmeasured edges")
let equalEdges = triangle.map { SimilarityPair(first: $0.first, second: $0.second, distance: 0.2) }
check(SimilarityGrouping.minimumSpanningTree(photos: Array(chainPhotos.prefix(3)), pairs: equalEdges, threshold: 0.5).map(\.id) == SimilarityGrouping.minimumSpanningTree(photos: Array(chainPhotos.prefix(3)), pairs: equalEdges.reversed(), threshold: 0.5).map(\.id), "Equal-score MST is deterministic")
let reversedDuplicate = SimilarityPair(first: "1", second: "0", distance: 0.1)
check(SimilarityGrouping.minimumSpanningTree(photos: Array(chainPhotos.prefix(3)), pairs: triangle + [reversedDuplicate], threshold: 0.5).count == 2, "Reversed duplicate edges do not create extra links")

// MARK: - Similarity ordering (spine + cheapest-gap insertion)

func orderIDs(_ photos: [TimedPhoto], _ pairs: [SimilarityPair], _ threshold: Float) -> [String] {
    SimilarityGrouping.similarityOrder(photos: photos, pairs: pairs, threshold: threshold).map(\.id)
}

// A pure chain 0-1-2-3-4 with increasing edges should stay in chain order.
let orderChainPhotos = (0..<5).map { photo(String($0), Double($0)) }
let orderChainPairs = (0..<4).map { SimilarityPair(first: String($0), second: String($0 + 1), distance: 0.1) }
let chainOrder = orderIDs(orderChainPhotos, orderChainPairs, 0.5)
check(chainOrder == ["0", "1", "2", "3", "4"] || chainOrder == ["4", "3", "2", "1", "0"], "Pure chain keeps chain adjacency (either direction)")
check(Set(chainOrder) == Set(["0", "1", "2", "3", "4"]), "Ordering preserves all members")

// No edges at all → falls back to the input order.
check(orderIDs(orderChainPhotos, [], 0.5) == ["0", "1", "2", "3", "4"], "No measured edges falls back to input order")

// Two photos are returned unchanged (guard count > 2).
let twoPhotos = [photo("a", 0), photo("b", 1)]
check(orderIDs(twoPhotos, [SimilarityPair(first: "a", second: "b", distance: 0.1)], 0.5).count == 2, "Two-photo group returned as-is")

// Star: center C tightly linked to A,B,D. Spine is the two longest arms;
// remaining arm inserts next to C. All members present, deterministic.
let starPhotos = ["A", "B", "C", "D"].enumerated().map { photo($0.element, Double($0.offset)) }
let starPairs = [
    SimilarityPair(first: "C", second: "A", distance: 0.1),
    SimilarityPair(first: "C", second: "B", distance: 0.2),
    SimilarityPair(first: "C", second: "D", distance: 0.3),
]
let starOrder = orderIDs(starPhotos, starPairs, 0.5)
check(Set(starOrder) == Set(["A", "B", "C", "D"]), "Star ordering keeps all members")
check(starOrder == orderIDs(starPhotos.reversed(), starPairs.reversed(), 0.5), "Star ordering is deterministic under input reordering")
// C must be adjacent to at least two of its arms (it's the hub).
let cIndex = starOrder.firstIndex(of: "C")!
let cNeighbors = Set([cIndex - 1, cIndex + 1].filter { starOrder.indices.contains($0) }.map { starOrder[$0] })
check(cNeighbors.count == 2, "Hub sits between two neighbors")

// Isolated photo (no edges) is appended at the end after connected members.
let withIsolated = orderChainPhotos + [photo("z", 100)]
let isoOrder = orderIDs(withIsolated, orderChainPairs, 0.5)
check(isoOrder.last == "z", "Isolated photo is appended at the end")
check(Set(isoOrder) == Set(["0", "1", "2", "3", "4", "z"]), "Isolated ordering preserves all members")

// Off-spine node prefers the cheaper gap. Chain 0-1-2-3 plus X measured close
// to 1 (0.05) — X should land adjacent to 1.
let insertPhotos = (0..<4).map { photo(String($0), Double($0)) } + [photo("X", 10)]
let insertPairs = [
    SimilarityPair(first: "0", second: "1", distance: 0.1),
    SimilarityPair(first: "1", second: "2", distance: 0.1),
    SimilarityPair(first: "2", second: "3", distance: 0.1),
    SimilarityPair(first: "1", second: "X", distance: 0.05),
]
let insertOrder = orderIDs(insertPhotos, insertPairs, 0.5)
let xIndex = insertOrder.firstIndex(of: "X")!
let xNeighbors = Set([xIndex - 1, xIndex + 1].filter { insertOrder.indices.contains($0) }.map { insertOrder[$0] })
check(xNeighbors.contains("1"), "Off-spine node inserts adjacent to its closest match")

// MARK: - Geo-proximity gating

func geoPhoto(_ id: String, _ seconds: Double, _ lat: Double?, _ lon: Double?) -> TimedPhoto {
    TimedPhoto(id: id, date: Date(timeIntervalSince1970: seconds), latitude: lat, longitude: lon)
}

// Haversine sanity: ~1 degree of latitude ≈ 111 km.
let oneDegLat = SequenceGrouping.greatCircleMeters(0, 0, 1, 0)
check(abs(oneDegLat - 111_195) < 500, "One degree of latitude is ~111 km")
check(SequenceGrouping.greatCircleMeters(37.0, -122.0, 37.0, -122.0) == 0, "Same point is zero distance")

// SF (37.7749,-122.4194) to LA (34.0522,-118.2437) ≈ 559 km.
let sfToLA = SequenceGrouping.greatCircleMeters(37.7749, -122.4194, 34.0522, -118.2437)
check(abs(sfToLA - 559_000) < 10_000, "SF→LA is roughly 559 km")

// geoFiltered: both close → kept; both far → dropped; missing coord → kept.
let geoPhotos = [
    geoPhoto("near1", 0, 37.7749, -122.4194),
    geoPhoto("near2", 1, 37.7750, -122.4195),   // ~15 m from near1
    geoPhoto("far",   2, 34.0522, -118.2437),    // ~559 km away
    geoPhoto("nogeo", 3, nil, nil),
]
let allComparisons = [
    CandidateComparison("near1", "near2"),
    CandidateComparison("near1", "far"),
    CandidateComparison("near1", "nogeo"),
]
let gated = Set(SequenceGrouping.geoFiltered(allComparisons, photos: geoPhotos, maxMeters: 1000))
check(gated.contains(CandidateComparison("near1", "near2")), "Nearby pair is kept")
check(!gated.contains(CandidateComparison("near1", "far")), "Far pair beyond 1 km is dropped")
check(gated.contains(CandidateComparison("near1", "nogeo")), "Pair missing a coordinate is always kept")

// Larger radius keeps the far pair.
let wide = Set(SequenceGrouping.geoFiltered(allComparisons, photos: geoPhotos, maxMeters: 1_000_000))
check(wide.contains(CandidateComparison("near1", "far")), "Far pair kept when radius exceeds distance")

// TimedPhoto without coordinates reports hasCoordinate == false.
check(!geoPhoto("x", 0, nil, nil).hasCoordinate, "Missing coordinate flagged")
check(geoPhoto("y", 0, 1, 2).hasCoordinate, "Present coordinate flagged")

// MARK: - Incremental (ranged) neighborhood building

// A dense run of 10 photos 1s apart: batched neighborhoods across ranges must
// yield the same set of comparisons as one full pass (no boundary pairs lost).
let densePhotos = (0..<10).map { photo(String($0), Double($0)) }
let sortedDense = SequenceGrouping.sortedByDate(densePhotos)

let fullComparisons = Set(SequenceGrouping.comparisons(SequenceGrouping.groups(densePhotos)))
let batchA = SequenceGrouping.neighborhoods(in: sortedDense, anchorRange: 0..<5)
let batchB = SequenceGrouping.neighborhoods(in: sortedDense, anchorRange: 5..<10)
let batchedComparisons = Set(SequenceGrouping.comparisons(batchA) + SequenceGrouping.comparisons(batchB))
check(batchedComparisons == fullComparisons, "Batched ranges cover the same comparisons as a full pass")

// A single batch reaches neighbors outside its own range (boundary complete).
let boundaryPair = CandidateComparison("4", "5")
check(Set(SequenceGrouping.comparisons(batchA)).contains(boundaryPair), "Batch anchors compare across the range boundary")

// nil range equals the whole array.
let allViaNil = SequenceGrouping.neighborhoods(in: sortedDense, anchorRange: nil)
check(SequenceGrouping.comparisons(allViaNil).count == SequenceGrouping.comparisons(SequenceGrouping.groups(densePhotos)).count, "nil anchorRange matches groups(_:)")

// MARK: - Scan order (direction + start-date window)

let orderPhotos = (0..<6).map { photo(String($0), Double($0 * 10)) } // dates 0,10,...,50

// Direction newer → ascending by date.
let newerAll = SequenceGrouping.scanOrdered(orderPhotos, direction: .newer, startDate: nil).map(\.id)
check(newerAll == ["0", "1", "2", "3", "4", "5"], "Newer direction scans oldest first")

// Direction older → descending by date.
let olderAll = SequenceGrouping.scanOrdered(orderPhotos, direction: .older, startDate: nil).map(\.id)
check(olderAll == ["5", "4", "3", "2", "1", "0"], "Older direction scans newest first")

// Flipping direction reverses the whole ordered array.
check(newerAll == olderAll.reversed(), "Direction flip reverses order")

// Start date, newer: keep on/after the start, oldest first.
let startNewer = SequenceGrouping.scanOrdered(orderPhotos, direction: .newer, startDate: Date(timeIntervalSince1970: 25)).map(\.id)
check(startNewer == ["3", "4", "5"], "Newer + start keeps on/after start, ascending")

// Start date, older: keep on/before the start, newest first.
let startOlder = SequenceGrouping.scanOrdered(orderPhotos, direction: .older, startDate: Date(timeIntervalSince1970: 25)).map(\.id)
check(startOlder == ["2", "1", "0"], "Older + start keeps on/before start, descending")

// Start date exactly on a photo's date includes that photo (boundary inclusive).
let boundaryNewer = SequenceGrouping.scanOrdered(orderPhotos, direction: .newer, startDate: Date(timeIntervalSince1970: 30)).map(\.id)
check(boundaryNewer.first == "3", "Start date boundary is inclusive (newer)")
let boundaryOlder = SequenceGrouping.scanOrdered(orderPhotos, direction: .older, startDate: Date(timeIntervalSince1970: 30)).map(\.id)
check(boundaryOlder.first == "3", "Start date boundary is inclusive (older)")

// Grouping is direction-agnostic: same comparisons regardless of scan order.
let dirCompNewer = Set(SequenceGrouping.comparisons(SequenceGrouping.neighborhoods(in: SequenceGrouping.scanOrdered(densePhotos, direction: .newer, startDate: nil), anchorRange: nil)))
let dirCompOlder = Set(SequenceGrouping.comparisons(SequenceGrouping.neighborhoods(in: SequenceGrouping.scanOrdered(densePhotos, direction: .older, startDate: nil), anchorRange: nil)))
check(dirCompNewer == dirCompOlder, "Comparisons are identical regardless of scan direction")

// MARK: - Incremental similarity grouping

/// The Similar list's original from-scratch regroup (PhotoLibraryModel's old
/// applyThreshold body), kept here as the reference the incremental version
/// must match.
func referenceDisplayGroups(progression: [String], pairs: [SimilarityPair], byID: [String: TimedPhoto], threshold: Float) -> [PhotoSequence] {
    let shown = Set(progression)
    var seen = Set<String>()
    var ordered: [TimedPhoto] = []
    for id in progression where seen.insert(id).inserted {
        if let photo = byID[id] { ordered.append(photo) }
    }
    for pair in pairs where shown.contains(pair.first) || shown.contains(pair.second) {
        for id in [pair.first, pair.second] where seen.insert(id).inserted {
            if let photo = byID[id] { ordered.append(photo) }
        }
    }
    return SimilarityGrouping.groups(photos: ordered, pairs: pairs, threshold: threshold)
}

func groupIDs(_ groups: [PhotoSequence]) -> [[String]] { groups.map { $0.photos.map(\.id) } }

/// Compare incremental output to the reference. Membership must match exactly,
/// and so must each scanned-containing group's position, first member, and
/// scanned members' order. Only the order of not-yet-scanned members may differ.
func groupingMismatch(_ incremental: [PhotoSequence], _ reference: [PhotoSequence], shown: Set<String>) -> String? {
    let inc = groupIDs(incremental), ref = groupIDs(reference)
    guard Set(inc.map(Set.init)) == Set(ref.map(Set.init)) else { return "membership \(inc) vs \(ref)" }
    let scannedPart: ([[String]]) -> [[String]] = { groups in
        groups.filter { shown.contains($0[0]) }.map { $0.filter { shown.contains($0) } }
    }
    guard scannedPart(inc) == scannedPart(ref) else { return "scanned order \(inc) vs \(ref)" }
    return nil
}

/// Deterministic RNG so failures reproduce.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

let groupThreshold: Float = 0.5
func pair(_ a: String, _ b: String, _ d: Float) -> SimilarityPair {
    SimilarityPair(first: min(a, b), second: max(a, b), distance: d)
}

// Hand-written cases.
do {
    let byID = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].map { ($0, photo($0, 0)) })
    var g = IncrementalSimilarityGrouping(threshold: groupThreshold)
    for id in ["a", "b", "c"] { g.markShown(id) }
    g.addPair(pair("a", "b", 0.1))
    g.addPair(pair("b", "c", 0.1))
    g.flush(photosByID: byID)
    check(groupIDs(g.groups) == [["a", "b", "c"]], "Incremental: chained edges form one group in scan order")
    var bridged = g
    bridged.removePhotos(["b"])
    bridged.flush(photosByID: byID)
    check(bridged.groups.isEmpty, "Incremental: deleting the bridge splits the group")
    g.addPair(pair("c", "d", 0.9))
    g.flush(photosByID: byID)
    check(groupIDs(g.groups) == [["a", "b", "c"]], "Incremental: a dissimilar pair pulls in but doesn't join")
}
do {
    let byID = Dictionary(uniqueKeysWithValues: ["s", "u"].map { ($0, photo($0, 0)) })
    var g = IncrementalSimilarityGrouping(threshold: groupThreshold)
    g.addPair(pair("s", "u", 0.1))
    g.flush(photosByID: byID)
    check(g.groups.isEmpty, "Incremental: pairs among unscanned photos stay hidden")
    g.markShown("s")
    g.flush(photosByID: byID)
    check(groupIDs(g.groups) == [["s", "u"]], "Incremental: scanning a photo pulls in its similar neighbor")
    g.markShown("u")
    g.flush(photosByID: byID)
    check(groupIDs(g.groups) == [["s", "u"]], "Incremental: scanning a pulled-in photo keeps the group")
}

// Randomized: replay add-pair / scan / delete sequences and compare every
// step against the reference. Neighbors are drawn from nearby indices, like
// the real time-local candidates.
do {
    var firstFailure: String?
    var rebuildFailure: String?
    var multiGroupSteps = 0
    for seed in 0..<300 where firstFailure == nil && rebuildFailure == nil {
        var rng = SplitMix64(state: UInt64(seed))
        let count = 8 + rng.below(25)
        var byID = Dictionary(uniqueKeysWithValues: (0..<count).map { ("p\($0)", photo("p\($0)", Double($0))) })
        var alive = (0..<count).map { "p\($0)" }
        var progression: [String] = []
        var pairs: [SimilarityPair] = []
        var measured = Set<CandidateComparison>()
        var g = IncrementalSimilarityGrouping(threshold: groupThreshold)
        for step in 0..<80 {
            let roll = rng.below(10)
            if roll < 5, alive.count > 1 {
                let i = rng.below(alive.count)
                let j = min(alive.count - 1, max(0, i + rng.below(9) - 4))
                guard i != j else { continue }
                let p = pair(alive[i], alive[j], Float(rng.below(100)) / 100)
                guard measured.insert(CandidateComparison(p.first, p.second)).inserted else { continue }
                pairs.append(p)
                g.addPair(p)
            } else if roll < 8 {
                let unscanned = alive.filter { !progression.contains($0) }
                guard !unscanned.isEmpty else { continue }
                let id = unscanned[rng.below(unscanned.count)]
                progression.append(id)
                g.markShown(id)
            } else if !alive.isEmpty {
                let removed = Set((0..<(1 + rng.below(3))).map { _ in alive[rng.below(alive.count)] })
                alive.removeAll { removed.contains($0) }
                progression.removeAll { removed.contains($0) }
                pairs.removeAll { removed.contains($0.first) || removed.contains($0.second) }
                measured = Set(pairs.map { CandidateComparison($0.first, $0.second) })
                for id in removed { byID[id] = nil }
                g.removePhotos(removed)
            }
            if rng.below(3) > 0 {   // also exercise several updates per flush
                g.flush(photosByID: byID)
                let reference = referenceDisplayGroups(progression: progression, pairs: pairs, byID: byID, threshold: groupThreshold)
                if reference.count > 1 { multiGroupSteps += 1 }
                if let mismatch = groupingMismatch(g.groups, reference, shown: Set(progression)) {
                    firstFailure = "seed \(seed) step \(step): \(mismatch)"
                    break
                }
                var rebuilt = IncrementalSimilarityGrouping(threshold: groupThreshold, progression: progression, pairs: pairs, photosByID: byID)
                rebuilt.flush(photosByID: byID)
                if groupIDs(rebuilt.groups) != groupIDs(reference) {
                    rebuildFailure = "seed \(seed) step \(step): \(groupIDs(rebuilt.groups)) vs \(groupIDs(reference))"
                    break
                }
            }
        }
    }
    check(firstFailure == nil, "Incremental grouping matches the full regroup across random add/scan/delete sequences \(firstFailure ?? "")")
    check(rebuildFailure == nil, "Rebuild matches the full regroup exactly \(rebuildFailure ?? "")")
    check(multiGroupSteps > 1_000, "Randomized grouping compared many multi-group states (\(multiGroupSteps))")
}
