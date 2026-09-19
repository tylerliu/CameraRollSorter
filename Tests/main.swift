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
check(SimilarityGrouping.groups(photos: chainPhotos.reversed(), pairs: chainPairs.reversed(), threshold: 0.5).first?.photos.map(\.id) == joined.first?.photos.map(\.id), "Group ordering is deterministic")

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
