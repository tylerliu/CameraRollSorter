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
