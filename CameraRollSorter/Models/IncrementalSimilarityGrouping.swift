import Foundation

/// Similarity groups for the Similar photos list, maintained incrementally so
/// streaming results and deletions don't regroup the whole library.
///
/// Rules (the same ones the list's full rebuild used):
/// - A photo is a *member* if it has been scanned ("shown"), or if it has any
///   measured pair with a shown photo. The second case pulls in neighbors whose
///   own scan hasn't run yet, so a group never drops a member.
/// - Groups are the connected components, among members only, of pairs whose
///   distance is within `threshold`. Components with 2+ members are shown.
/// - Shown photos rank by scan order; pulled-in photos rank after all of them.
///   Groups sort by their best-ranked member, and members sort by rank.
///
/// Updates stay local:
/// - `addPair` and `markShown` can only merge components (smaller into larger).
/// - `removePhotos` re-splits only the components that lost a member, by
///   walking that component's similar edges. Edges only link photos close in
///   time, so this never reaches the rest of the library.
/// - A threshold change re-qualifies every edge, so callers rebuild with
///   `init(threshold:progression:pairs:photosByID:)` instead.
///
/// One difference from a from-scratch rebuild: pulled-in (not yet scanned)
/// photos are ordered by when they were pulled in rather than by pair order.
/// Membership, scanned members' order, each group's first member (its id), and
/// the order of groups that contain a scanned photo are all identical.
nonisolated struct IncrementalSimilarityGrouping {
    let threshold: Float

    // Measured neighbors per photo at any distance, in arrival order. Decides
    // which unscanned photos are pulled in.
    private var neighbors: [String: [String]] = [:]
    // Neighbors whose distance is within the threshold (group edges).
    private var similar: [String: [String]] = [:]

    private var shown: Set<String> = []
    // Display rank of every member: shown photos first (scan order), then
    // pulled-in photos in the order they joined.
    private var rank: [String: Int] = [:]
    private var nextShownRank = 0
    private var nextPulledRank = IncrementalSimilarityGrouping.pulledTier
    private static let pulledTier = 1 << 48

    // Components over members. Every member belongs to exactly one.
    private var componentOf: [String: Int] = [:]
    private var components: [Int: Set<String>] = [:]
    private var nextComponentID = 0

    // Published groups: components with 2+ members, sorted by key (the rank of
    // their best-ranked member). Keys are unique since ranks are.
    private var orderedGroups: [(key: Int, component: Int)] = []
    private var groupKey: [Int: Int] = [:]
    private var sequences: [Int: PhotoSequence] = [:]
    // Components whose published group may be stale.
    private var dirty: Set<Int> = []

    /// An empty grouping (nothing scanned yet).
    init(threshold: Float) {
        self.threshold = threshold
    }

    /// Full rebuild from the current scan state, matching the old
    /// from-scratch regroup exactly (including pulled-in order). Use for global
    /// changes: threshold, scan-window restart, library reconcile.
    init(threshold: Float, progression: [String], pairs: [SimilarityPair], photosByID: [String: TimedPhoto]) {
        self.threshold = threshold
        for pair in pairs { indexPair(pair) }
        for id in progression where photosByID[id] != nil && shown.insert(id).inserted {
            rank[id] = nextShownRank
            nextShownRank += 1
        }
        for pair in pairs where shown.contains(pair.first) || shown.contains(pair.second) {
            for id in [pair.first, pair.second] where rank[id] == nil && photosByID[id] != nil {
                rank[id] = nextPulledRank
                nextPulledRank += 1
            }
        }
        let members = Set(rank.keys)
        for start in members where componentOf[start] == nil {
            makeComponent(collectComponent(from: start, within: members))
        }
    }

    // MARK: - Updates

    /// Record a newly measured pair. Merges groups when it's a similar edge
    /// between members, and pulls in an unscanned photo paired with a shown one.
    mutating func addPair(_ pair: SimilarityPair) {
        guard indexPair(pair) else { return }
        let a = pair.first, b = pair.second
        if shown.contains(a), componentOf[b] == nil { join(b) }
        if shown.contains(b), componentOf[a] == nil { join(a) }
        if qualifies(pair), let ca = componentOf[a], let cb = componentOf[b], ca != cb {
            merge(ca, cb)
        }
    }

    /// Mark a photo as scanned. It joins (or re-ranks within) its group, and
    /// pulls in every photo it has a measured pair with.
    mutating func markShown(_ id: String) {
        guard shown.insert(id).inserted else { return }
        rank[id] = nextShownRank
        nextShownRank += 1
        if let component = componentOf[id] {
            dirty.insert(component)   // its rank improved; group order may change
        } else {
            join(id)
        }
        for neighbor in neighbors[id] ?? [] where componentOf[neighbor] == nil {
            join(neighbor)
        }
    }

    /// Remove deleted photos and their pairs. Only the groups that lose a member
    /// are re-split. A pulled-in photo leaves too once it no longer has any
    /// shown neighbor.
    mutating func removePhotos(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var affected: Set<Int> = []
        var lostShownNeighbor: Set<String> = []
        for id in ids {
            if let component = componentOf.removeValue(forKey: id) {
                affected.insert(component)
                components[component]?.remove(id)
            }
            let wasShown = shown.remove(id) != nil
            rank[id] = nil
            for neighbor in neighbors.removeValue(forKey: id) ?? [] {
                neighbors[neighbor]?.removeAll { $0 == id }
                similar[neighbor]?.removeAll { $0 == id }
                if wasShown { lostShownNeighbor.insert(neighbor) }
            }
            similar[id] = nil
        }
        let shownNow = shown
        for id in lostShownNeighbor where !shownNow.contains(id) {
            guard let component = componentOf[id],
                  !(neighbors[id] ?? []).contains(where: { shownNow.contains($0) }) else { continue }
            componentOf[id] = nil
            components[component]?.remove(id)
            rank[id] = nil
            affected.insert(component)
        }
        for component in affected { split(component) }
    }

    // MARK: - Output

    /// Apply pending changes to `groups`. Cost is proportional to the groups
    /// that changed. Returns false when nothing changed.
    @discardableResult
    mutating func flush(photosByID: [String: TimedPhoto]) -> Bool {
        guard !dirty.isEmpty else { return false }
        // Drop every stale entry first: a key can move between components in
        // one flush (merge), so removing and inserting interleaved could hit
        // the wrong entry.
        for component in dirty {
            guard let key = groupKey.removeValue(forKey: component) else { continue }
            let index = lowerBound(of: key)
            if index < orderedGroups.count, orderedGroups[index].component == component {
                orderedGroups.remove(at: index)
            } else if let fallback = orderedGroups.firstIndex(where: { $0.component == component }) {
                orderedGroups.remove(at: fallback)   // shouldn't happen; keys are unique
            }
            sequences[component] = nil
        }
        for component in dirty {
            guard let members = components[component], members.count > 1 else { continue }
            let sorted = members.sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) }
            let photos = sorted.compactMap { photosByID[$0] }
            guard photos.count > 1, let key = rank[sorted[0]] else { continue }
            orderedGroups.insert((key, component), at: lowerBound(of: key))
            groupKey[component] = key
            sequences[component] = PhotoSequence(photos: photos)
        }
        dirty.removeAll(keepingCapacity: true)
        return true
    }

    /// Groups as of the last `flush`, in display order.
    var groups: [PhotoSequence] {
        orderedGroups.compactMap { sequences[$0.component] }
    }

    // MARK: - Internals

    private func qualifies(_ pair: SimilarityPair) -> Bool {
        pair.distance.isFinite && pair.distance >= 0 && pair.distance <= threshold
    }

    /// Add a pair to the neighbor indexes. Returns false for self-pairs and
    /// duplicates.
    @discardableResult
    private mutating func indexPair(_ pair: SimilarityPair) -> Bool {
        let a = pair.first, b = pair.second
        guard a != b, !(neighbors[a]?.contains(b) ?? false) else { return false }
        neighbors[a, default: []].append(b)
        neighbors[b, default: []].append(a)
        if qualifies(pair) {
            similar[a, default: []].append(b)
            similar[b, default: []].append(a)
        }
        return true
    }

    /// Add a non-member as a new member, connected to any member it's similar to.
    private mutating func join(_ id: String) {
        if rank[id] == nil {
            rank[id] = nextPulledRank
            nextPulledRank += 1
        }
        var component = makeComponent([id])
        for other in similar[id] ?? [] {
            if let otherComponent = componentOf[other], otherComponent != component {
                component = merge(component, otherComponent)
            }
        }
    }

    @discardableResult
    private mutating func makeComponent(_ members: Set<String>) -> Int {
        let id = nextComponentID
        nextComponentID += 1
        for member in members { componentOf[member] = id }
        components[id] = members
        dirty.insert(id)
        return id
    }

    /// Merge two components, relabeling the smaller one. Returns the survivor.
    @discardableResult
    private mutating func merge(_ a: Int, _ b: Int) -> Int {
        guard a != b, let countA = components[a]?.count, let countB = components[b]?.count else { return a }
        let (keep, drop) = countA >= countB ? (a, b) : (b, a)
        // Move the smaller set out (no copy of the larger one).
        let moved = components.removeValue(forKey: drop) ?? []
        for member in moved { componentOf[member] = keep }
        components[keep]?.formUnion(moved)
        dirty.insert(keep)
        dirty.insert(drop)
        return keep
    }

    /// Recompute connectivity of one component after it lost members.
    private mutating func split(_ component: Int) {
        dirty.insert(component)
        guard let remaining = components.removeValue(forKey: component) else { return }
        // Clear the old labels so each part is collected exactly once.
        for member in remaining { componentOf[member] = nil }
        for start in remaining where componentOf[start] == nil {
            makeComponent(collectComponent(from: start, within: remaining))
        }
    }

    /// Photos reachable from `start` over similar edges, staying within `allowed`.
    private func collectComponent(from start: String, within allowed: Set<String>) -> Set<String> {
        var found: Set<String> = [start]
        var stack = [start]
        while let id = stack.popLast() {
            for other in similar[id] ?? [] where allowed.contains(other) && found.insert(other).inserted {
                stack.append(other)
            }
        }
        return found
    }

    /// First index in `orderedGroups` whose key is >= `key`.
    private func lowerBound(of key: Int) -> Int {
        var low = 0, high = orderedGroups.count
        while low < high {
            let mid = (low + high) / 2
            if orderedGroups[mid].key < key { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
