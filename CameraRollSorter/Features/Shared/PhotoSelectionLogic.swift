import CoreGraphics
import Foundation

/// Pure selection and drag-select helpers for the photo-selection grid,
/// extracted from the drag-to-select logic in `LiveToStillView` so the shared
/// `PhotoSelectionGrid` (used by both Live → Still and Blurry photos) and the
/// property tests can call them without any SwiftUI `@State` or PhotoKit
/// dependencies.
///
/// Everything here is a free function over plain values (`Set<String>`,
/// arrays of ids, indices, `CGPoint`/`CGRect`) so it is trivially
/// `Sendable`-friendly and unit/property testable in isolation. The view keeps
/// the `@State` and gesture wiring and delegates the math to these functions,
/// keeping behavior identical to the existing Live → Still flow.
///
/// Requirements: 6.1, 6.2 (toggle), 6.3, 6.6 (paint range + edge auto-scroll),
/// 6.4 (paint/scroll axis decision), 6.7 (Select All).
enum PhotoSelectionLogic {

    // MARK: - Toggle (Requirements 6.1, 6.2)

    /// Toggle `id`'s membership in `selection`, returning the updated set.
    /// If `id` is present it is removed; otherwise it is inserted. Every other
    /// member is left unchanged. Applying this twice is the identity.
    static func toggle(_ id: String, in selection: Set<String>) -> Set<String> {
        var next = selection
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        return next
    }

    // MARK: - Select All (Requirement 6.7)

    /// The selection produced by "Select All": every id in `ids`. Because it is
    /// the full set, it is a superset of any prior selection over the same ids.
    static func selectAll(ids: [String]) -> Set<String> {
        Set(ids)
    }

    // MARK: - Paint range (Requirements 6.3, 6.6)

    /// Whether a fresh drag anchored on the cell at `anchorIndex` should paint
    /// selections (`true`) or deselections (`false`). Mirrors the view's rule:
    /// the action is decided by the anchor cell — if it was unselected the drag
    /// selects, otherwise it deselects.
    static func dragSelects(anchorIndex: Int, ids: [String], base: Set<String>) -> Bool {
        guard ids.indices.contains(anchorIndex) else { return true }
        return !base.contains(ids[anchorIndex])
    }

    /// Apply a drag's single action to every item in the inclusive index range
    /// between `anchorIndex` and `targetIndex`, starting from the pre-drag
    /// `base` selection so backtracking reverts cleanly.
    ///
    /// - `selects == true`  → every id in the swept range is inserted.
    /// - `selects == false` → every id in the swept range is removed.
    ///
    /// Items outside the range keep their `base` state. Out-of-range indices
    /// (or an empty `ids`) yield `base` unchanged, matching the view's guards.
    static func paintRange(
        anchorIndex: Int,
        targetIndex: Int,
        base: Set<String>,
        ids: [String],
        selects: Bool
    ) -> Set<String> {
        guard ids.indices.contains(anchorIndex),
              ids.indices.contains(targetIndex) else { return base }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        var next = base
        for i in lower...upper where ids.indices.contains(i) {
            let id = ids[i]
            if selects {
                next.insert(id)
            } else {
                next.remove(id)
            }
        }
        return next
    }

    // MARK: - Paint / scroll decision (Requirement 6.4)

    /// Whether a drag translation should be treated as a selection paint.
    /// Horizontal/diagonal drags paint (lock scrolling); a mostly-vertical drag
    /// scrolls and leaves the selection unchanged. The rule is `|dx| >= |dy|`,
    /// so a perfectly diagonal drag counts as a paint.
    static func isPaint(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) >= abs(dy)
    }

    // MARK: - Edge auto-scroll mapping (Requirement 6.6)

    /// The direction (-1 up, 0 none, +1 down) and 0…1 intensity of edge
    /// auto-scroll for a finger at `point` relative to `viewport`, using the
    /// given `edgeMargin`.
    ///
    /// The finger auto-scrolls up when it sits within `edgeMargin` of the top
    /// edge and down when within `edgeMargin` of the bottom edge; otherwise the
    /// direction is `0`. Intensity ramps 0 → 1 across the margin: 0 at the
    /// margin boundary and 1 at (or beyond) the very edge, so scrolling starts
    /// slow and accelerates as the finger nears the edge. When the direction is
    /// `0` the intensity is `0`. A non-positive `viewport` height disables
    /// auto-scroll entirely.
    static func autoScroll(
        for point: CGPoint,
        viewport: CGRect,
        edgeMargin: CGFloat
    ) -> (direction: Int, intensity: Double) {
        guard viewport.height > 0, edgeMargin > 0 else { return (0, 0) }
        let topZone = viewport.minY + edgeMargin
        let bottomZone = viewport.maxY - edgeMargin
        if point.y < topZone {
            let intensity = min(1, Double((topZone - point.y) / edgeMargin))
            return (-1, max(0, intensity))
        } else if point.y > bottomZone {
            let intensity = min(1, Double((point.y - bottomZone) / edgeMargin))
            return (1, max(0, intensity))
        } else {
            return (0, 0)
        }
    }

    /// The row step for one auto-scroll tick given the edge `intensity` (0…1)
    /// and the maximum step. Ramps 1 row at intensity 0 to `maxStep` rows at
    /// intensity 1, mirroring `runAutoScroll` in the view.
    static func autoScrollStep(intensity: Double, maxStep: Int) -> Int {
        let clamped = min(1, max(0, intensity))
        return 1 + Int((Double(maxStep - 1) * clamped).rounded())
    }
}
