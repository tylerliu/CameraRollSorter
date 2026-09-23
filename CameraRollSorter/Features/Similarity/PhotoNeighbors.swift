import Photos

/// Looks up the photos captured just before and just after a given asset, by
/// capture time, across the WHOLE photo library (not just a flagged subset).
///
/// Used by the Low-aesthetic detail view to show a flagged photo's temporal
/// neighbors, so the user can glance at whether a better "nearby shot" exists
/// right next to the one under review.
enum PhotoNeighbors {
    /// The `count` nearest images captured before and after `identifier`, by
    /// `creationDate`, returned as `(before, after)` where `before` is in
    /// chronological order (oldest → the target) and `after` is chronological
    /// (the target → newest). The target itself and any asset missing a capture
    /// date are excluded. Videos are excluded to match the image-only flow.
    ///
    /// Returns fewer than `count` on a side when the library runs out (e.g. the
    /// newest or oldest photo has no neighbor on one side).
    static func around(_ identifier: String, count: Int = 2) -> (before: [String], after: [String]) {
        guard count > 0,
              let target = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let targetDate = target.creationDate else {
            return ([], [])
        }

        let before = fetchSide(from: targetDate, targetID: identifier, ascending: false, count: count)
        // `before` is fetched newest→oldest; present it oldest→newest so the
        // strip reads left-to-right in chronological order up to the target.
        let after = fetchSide(from: targetDate, targetID: identifier, ascending: true, count: count)
        return (before.reversed(), after)
    }

    /// Fetches up to `count` image assets on one side of `targetDate`.
    /// `ascending == false` walks backwards in time (older); `true` walks
    /// forwards (newer). The predicate is inclusive of equal timestamps so
    /// bursts captured in the same second still surface as neighbors, then the
    /// target id is filtered out and the list capped.
    private static func fetchSide(
        from targetDate: Date,
        targetID: String,
        ascending: Bool,
        count: Int
    ) -> [String] {
        let options = PHFetchOptions()
        // Same-second neighbors are common in bursts, so compare inclusively and
        // drop the target by id afterwards rather than with a strict date bound.
        let comparison = ascending ? ">=" : "<="
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate \(comparison) %@",
            PHAssetMediaType.image.rawValue,
            targetDate as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
        // Fetch a couple extra to absorb the target itself and any same-time
        // ties before capping to `count`.
        options.fetchLimit = count + 4

        let assets = PHAsset.fetchAssets(with: options)
        var ids: [String] = []
        assets.enumerateObjects { asset, _, stop in
            guard asset.localIdentifier != targetID else { return }
            ids.append(asset.localIdentifier)
            if ids.count >= count { stop.pointee = true }
        }
        return ids
    }
}
