import SwiftUI

/// Shared scroll-position memory for the Similar photos list and the Live→Still
/// grid. Both track the top-visible row so navigating away and back restores the
/// position, and both must survive the list mutating while scanning appends rows.
///
/// Usage per view: own one as `@State`, tag each row `.id(itemID)`, call
/// `onRowAppear/onRowDisappear` from the row, expose the current top id via
/// `topVisibleID(in:)`, and call `restore(_:proxy:)` once in the container's
/// `.onAppear`. Tracking is suspended until the restore scroll settles so the
/// pre-jump top rows don't clobber the saved anchor.
@Observable
final class ScrollAnchorTracker {
    private var didAttemptRestore = false
    private var trackingEnabled = false
    // Indices of rows currently on screen; the smallest is the anchor. A Set is
    // used so appending rows at the bottom never changes which row is topmost.
    private var visibleIndices: Set<Int> = []

    func onRowAppear(_ index: Int) { visibleIndices.insert(index) }
    func onRowDisappear(_ index: Int) { visibleIndices.remove(index) }

    /// Smallest/largest on-screen row index (for edge auto-scroll targeting).
    /// Ungated — auto-scroll needs these regardless of restore state.
    var minVisibleIndex: Int? { visibleIndices.min() }
    var maxVisibleIndex: Int? { visibleIndices.max() }

    /// Topmost visible row index for SAVING the anchor — nil until tracking is
    /// enabled (after the restore settles) so the pre-jump top rows don't
    /// clobber the saved anchor. Callers index their own item array with this,
    /// avoiding a per-event allocation of the full id array.
    var topVisibleIndexForAnchor: Int? {
        trackingEnabled ? visibleIndices.min() : nil
    }

    /// Jump back to `anchorID` once, on the container's first appear (a lazy
    /// list won't auto-restore an unmaterialized row). Enables tracking only
    /// after the scroll settles so the saved anchor isn't overwritten meanwhile.
    func restore(_ anchorID: String?, proxy: ScrollViewProxy) {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        guard let anchorID else { trackingEnabled = true; return }
        DispatchQueue.main.async {
            proxy.scrollTo(anchorID, anchor: .top)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.trackingEnabled = true }
        }
    }
}
