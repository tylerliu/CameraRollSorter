import SwiftUI

/// Collects each grid cell's frame (in GLOBAL space) keyed by item id, so
/// drag-select can hit-test which cell is under the finger and edge auto-scroll
/// can measure the finger's distance to the viewport edges. Shared by every
/// screen that renders `PhotoSelectionGrid` (Live → Still, Blurry photos, …);
/// previously a private copy lived in `LiveToStillView`.
struct CellFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The reusable photo-selection grid shared by the Live → Still and Blurry
/// photos flows. It encapsulates everything the two screens have in common:
///
/// - an adaptive `LazyVGrid` of `PhotoThumbnail` cells with an always-visible
///   selection tick,
/// - tap-to-open the full-screen `PhotoDetailPager` (which reuses
///   `ZoomablePhotoView`) in view mode, tap-to-toggle in select mode,
/// - the full Photos-style rubber-band drag-select apparatus (paint vs. scroll
///   decision, scroll lock, and edge auto-scroll), delegating all math to
///   `PhotoSelectionLogic`,
/// - `ScrollAnchorTracker`-based scroll restoration across navigation,
/// - the pinned `ScanControlsHeader`, the incremental `scanMore` hook, the
///   "Finding more…" footer, and parameterized empty/scanning states,
/// - the Select / Done / Select All toolbar.
///
/// The host owns the model and supplies the item ids, selection binding, scroll
/// anchor binding, scan state/closures, header bindings, navigation title,
/// empty-state configuration, and an `actionBar` slot rendered via
/// `safeAreaInset(edge: .bottom)`. Behavior is identical to the original
/// Live → Still implementation — the logic was moved here verbatim.
struct PhotoSelectionGrid<ActionBar: View>: View {
    // MARK: Data
    /// Ordered ids of the detected photos driving the grid and detail pager.
    let ids: [String]
    /// Current selection (host-owned so the action bar can act on it).
    @Binding var selection: Set<String>
    /// Session-only top-visible cell used to restore scroll on return.
    @Binding var scrollAnchorID: String?

    // MARK: Scan state
    let isScanning: Bool
    let hasScanned: Bool
    let hasMoreToScan: Bool
    /// Keep a rolling buffer classified ahead of the viewed row.
    let scanMore: (Int) -> Void
    /// Re-window/rebuild when a scan control changes.
    let applyScanSettings: () -> Void

    // MARK: Scan-window controls (bound to ScanControlsHeader)
    @Binding var scanDirectionRaw: String
    @Binding var scanStartEnabled: Bool
    @Binding var scanStartInterval: Double
    let libraryDateRange: ClosedRange<Date>?

    // MARK: Presentation
    let navigationTitle: LocalizedStringKey
    /// Text shown in the scanning-with-no-items placeholder.
    let scanningText: LocalizedStringKey
    /// The empty state shown when a scan completed with no results.
    let emptyState: AnyView
    /// When true, the full-screen detail view shows a strip of each photo's
    /// nearest temporal neighbors. Used by the Low-aesthetic flow; off elsewhere.
    var showsNeighbors: Bool = false
    /// Bottom action bar (Convert / Delete / …), rendered via safeAreaInset.
    /// Receives whether the grid is currently in select mode so the host can
    /// tailor its selection hint text (e.g. "Tap or drag to select").
    @ViewBuilder let actionBar: (_ isSelecting: Bool) -> ActionBar

    // MARK: - Selection UI state (owned here; the host only sees `selection`)
    @State private var isSelecting = false
    @State private var detailID: String?

    // Frames of each cell in GLOBAL space, keyed by id, so a drag in select
    // mode can hit-test which cell is under the finger. Only used while
    // `isSelecting`.
    @State private var cellFrames: [String: CGRect] = [:]
    // Rubber-band drag state (Photos-style): the drag applies one action to
    // EVERY item between the start cell and the current cell (by index order),
    // so dragging down covers whole rows. `dragBaseSelection` snapshots the
    // selection at drag start so the range can be recomputed live (and reverted
    // when backtracking); `dragAnchorIndex` is the start cell; `dragSelects`
    // is the action decided by the start cell (select if it was unselected).
    @State private var dragBaseSelection: Set<String>?
    @State private var dragAnchorIndex: Int?
    @State private var dragSelects = true
    // Per-drag decision (nil = undecided) and the resulting scroll lock: when a
    // drag is judged a paint we set scrollLocked, which disables the ScrollView
    // mid-gesture so it stops following the finger.
    @State private var dragIsPaint: Bool?
    @State private var scrollLocked = false

    // Viewport frame (global space) and the current finger position, so a paint
    // drag near the top/bottom edge auto-scrolls the grid. `autoScrollDir` is
    // -1 (up), 0 (none), or +1 (down); a task advances the scroll while nonzero.
    @State private var viewportFrame: CGRect = .zero
    @State private var dragLocation: CGPoint = .zero
    @State private var autoScrollDir = 0
    // 0→1 ramp of how deep the finger is into the edge margin; scales scroll speed.
    @State private var autoScrollIntensity: Double = 0
    private let edgeMargin: CGFloat = 70

    @State private var scrollTracker = ScrollAnchorTracker()

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 3)]

    var body: some View {
        VStack(spacing: 0) {
            ScanControlsHeader(
                direction: $scanDirectionRaw,
                startEnabled: $scanStartEnabled,
                startInterval: $scanStartInterval,
                dateRange: libraryDateRange,
                onChange: applyScanSettings
            )
            Divider()
            content
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select All") { selection = PhotoSelectionLogic.selectAll(ids: ids) }
                        .disabled(ids.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Exit select mode but KEEP the selection so it can still be
                    // acted on (the tick stays visible in normal mode).
                    Button("Done") { isSelecting = false }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { isSelecting = true }
                        .disabled(ids.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar(isSelecting) }
        .fullScreenCover(isPresented: detailPresented) {
            PhotoDetailPager(
                identifiers: ids,
                currentID: $detailID,
                selection: optionalSelectionBinding,
                showsNeighbors: showsNeighbors
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if isScanning && ids.isEmpty {
            Spacer(); ProgressView(scanningText); Spacer()
        } else if hasScanned && ids.isEmpty && !isScanning {
            emptyState
        } else {
            grid
        }
    }

    private var detailPresented: Binding<Bool> {
        Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } })
    }

    /// Bridges the non-optional `selection` to the pager's optional binding so
    /// the pager shows (and toggles) a selection tick.
    private var optionalSelectionBinding: Binding<Set<String>?> {
        Binding(get: { selection }, set: { if let new = $0 { selection = new } })
    }

    /// Save the topmost visible cell as the scroll anchor on the host. Indexes
    /// directly (no per-event allocation of the full id array), matching the
    /// scroll-tracking optimization used by SimilarPhotosView.
    private func updateAnchor() {
        guard let top = scrollTracker.topVisibleIndexForAnchor, ids.indices.contains(top) else { return }
        scrollAnchorID = ids[top]
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        cell(for: id).id(id)
                            // Keep a rolling buffer classified ahead of the row
                            // being viewed, and track the topmost visible cell so
                            // scroll position survives navigation.
                            .onAppear {
                                scanMore(index)
                                scrollTracker.onRowAppear(index)
                                updateAnchor()
                            }
                            .onDisappear {
                                scrollTracker.onRowDisappear(index)
                                updateAnchor()
                            }
                    }
                }
                .padding(3)

                // Auto-continue classifying when more remains and the bottom is
                // reached.
                if hasMoreToScan {
                    HStack { ProgressView(); Text("Finding more…").font(.caption).foregroundStyle(.secondary) }
                        .padding(.vertical, 8)
                        .onAppear { scanMore(ids.count) }
                }
            }
            // Lock the ScrollView the instant a drag is judged a paint, so the
            // content stops scrolling and only painting continues. A vertical
            // drag leaves it unlocked, so it scrolls normally.
            .scrollDisabled(scrollLocked)
            // Capture the viewport frame (global space) for edge auto-scroll.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewportFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, f in viewportFrame = f }
                }
            )
            // Collect visible cell frames (global space) for drag hit-testing.
            .onPreferenceChange(CellFramePreferenceKey.self) { cellFrames = $0 }
            // Drag-to-paint selection while selecting, as a SIMULTANEOUS gesture
            // so a vertical drag still scrolls. On the first move we judge the
            // direction: a horizontal/diagonal drag is a paint → we lock the
            // ScrollView (`.scrollDisabled`) so only painting happens; a mostly
            // vertical drag is a scroll → we don't paint and leave it scrolling.
            .simultaneousGesture(isSelecting ? dragSelectGesture : nil)
            // Drive edge auto-scroll while a paint drag sits near an edge.
            .onChange(of: autoScrollDir) { _, dir in
                guard dir != 0 else { return }
                Task { await runAutoScroll(proxy: proxy) }
            }
            // On first appear, jump back to the remembered cell.
            .onAppear { scrollTracker.restore(scrollAnchorID, proxy: proxy) }
        }
    }

    private func cell(for id: String) -> some View {
        let selected = selection.contains(id)
        return PhotoThumbnail(identifier: id, size: 120, fill: true, cornerRadius: 4)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 4).stroke(.tint, lineWidth: 3)
                }
            }
            // Tap the body: in select mode toggle the tick; otherwise open the
            // large zoomable viewer.
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting { toggle(id) } else { detailID = id }
            }
            // Selection tick. Always shown (like the original design) so single
            // photos can be picked without entering select mode. In normal mode
            // it's a tap target that toggles selection; in select mode the whole
            // cell already toggles, so it's just an indicator.
            .overlay(alignment: .bottomTrailing) {
                let tick = Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.4))
                    .font(.title3)
                    .padding(5)
                if isSelecting {
                    tick
                } else {
                    Button { toggle(id) } label: { tick.contentShape(Circle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(selected ? "Selected. Tap to deselect." : "Not selected. Tap to select.")
                }
            }
            // Report this cell's frame in GLOBAL space for drag-select hit-
            // testing and edge auto-scroll while selecting.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CellFramePreferenceKey.self,
                        value: [id: geo.frame(in: .global)]
                    )
                }
            )
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Rubber-band drag-to-select, active only while `isSelecting`. A vertical
    /// drag scrolls; a horizontal/diagonal drag paints, locking the ScrollView
    /// via `.scrollDisabled` so it stops mid-gesture. Applies one action
    /// (decided by the start cell) to every item in the index range between the
    /// anchor and the cell under the finger, and auto-scrolls near the edges.
    private var dragSelectGesture: some Gesture {
        // minimumDistance 6 so the paint/scroll decision is made early, before
        // much scrolling happens.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                // Decide once per drag: horizontal/diagonal → paint (lock the
                // ScrollView so it stops); mostly vertical → scroll (no paint).
                if dragIsPaint == nil {
                    let paint = PhotoSelectionLogic.isPaint(
                        dx: value.translation.width, dy: value.translation.height
                    )
                    dragIsPaint = paint
                    if paint { scrollLocked = true }
                }
                guard dragIsPaint == true else { return }

                dragLocation = value.location
                if dragAnchorIndex == nil, let index = itemIndex(at: value.location) {
                    dragAnchorIndex = index
                    dragBaseSelection = selection
                    dragSelects = PhotoSelectionLogic.dragSelects(
                        anchorIndex: index, ids: ids, base: selection
                    )
                }
                paintRange(to: value.location)
                updateAutoScroll(for: value.location)
            }
            .onEnded { _ in
                dragIsPaint = nil
                dragAnchorIndex = nil
                dragBaseSelection = nil
                autoScrollDir = 0
                scrollLocked = false
            }
    }

    /// Paint to the cell under `point` (no-op if it's not over a cell, keeping
    /// the last range).
    private func paintRange(to point: CGPoint) {
        if let index = itemIndex(at: point) { paintRange(toIndex: index) }
    }

    /// Set the auto-scroll direction AND intensity from the finger's distance to
    /// the viewport edges, delegating the mapping to `PhotoSelectionLogic`.
    private func updateAutoScroll(for point: CGPoint) {
        let result = PhotoSelectionLogic.autoScroll(
            for: point, viewport: viewportFrame, edgeMargin: edgeMargin
        )
        autoScrollDir = result.direction
        autoScrollIntensity = result.intensity
    }

    /// While the finger sits in an edge margin, step the scroll toward off-screen
    /// rows and extend the selection to reach them. The step size scales with
    /// `autoScrollIntensity` (edge proximity), so it accelerates from ~1 row per
    /// tick at the margin boundary to `maxScrollStep` rows at the very edge.
    private func runAutoScroll(proxy: ScrollViewProxy) async {
        let maxScrollStep = 8
        while autoScrollDir != 0 {
            let dir = autoScrollDir
            // 1 row at intensity 0 → maxScrollStep rows at intensity 1.
            let step = PhotoSelectionLogic.autoScrollStep(
                intensity: autoScrollIntensity, maxStep: maxScrollStep
            )
            let targetIndex: Int
            if dir < 0 {
                targetIndex = max(0, (scrollTracker.minVisibleIndex ?? 0) - step)
            } else {
                targetIndex = min(ids.count - 1, (scrollTracker.maxVisibleIndex ?? 0) + step)
            }
            if ids.indices.contains(targetIndex) {
                withAnimation(.linear(duration: 0.2)) {
                    proxy.scrollTo(ids[targetIndex], anchor: dir < 0 ? .top : .bottom)
                }
                if dir > 0 { scanMore(targetIndex) }
                // Extend the paint range to the row we scrolled toward, so the
                // selection keeps growing in the scroll direction rather than
                // snapping back to the (now off-screen) finger cell.
                paintRange(toIndex: targetIndex)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Apply the drag's action to every item between the anchor and `index`
    /// (inclusive), starting from the pre-drag snapshot so backtracking reverts.
    private func paintRange(toIndex index: Int) {
        guard let anchor = dragAnchorIndex, let base = dragBaseSelection else { return }
        selection = PhotoSelectionLogic.paintRange(
            anchorIndex: anchor,
            targetIndex: index,
            base: base,
            ids: ids,
            selects: dragSelects
        )
    }

    /// The index in `ids` of the cell under `point` (global space), or nil if
    /// the point isn't over a known (visible) cell.
    private func itemIndex(at point: CGPoint) -> Int? {
        guard let id = cellFrames.first(where: { $0.value.contains(point) })?.key else { return nil }
        return ids.firstIndex(of: id)
    }

    private func toggle(_ id: String) {
        selection = PhotoSelectionLogic.toggle(id, in: selection)
    }
}
