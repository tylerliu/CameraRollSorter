import Photos
import PhotosUI
import SwiftUI

/// Detail screen for the "Live → Still" category. Lists convertible Live Photos
/// (genuine Live and Long Exposure only — no Loop/Bounce) and converts the
/// selected ones to plain stills, preserving metadata. Owns its own model so
/// scanning runs independently of similarity analysis.
struct LiveToStillView: View {
    @State var model: LiveToStillModel

    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    @State private var isConverting = false
    @State private var showsConfirm = false
    @State private var conversionError: String?
    @State private var detailID: String?

    // Frames of each cell in the grid's coordinate space, keyed by item id, so a
    // drag in select mode can hit-test which cell is under the finger. Only used
    // while `isSelecting`.
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
    private let edgeMargin: CGFloat = 70

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 3)]

    var body: some View {
        VStack(spacing: 0) {
            ScanControlsHeader(
                direction: $model.scanDirectionRaw,
                startEnabled: $model.scanStartEnabled,
                startInterval: $model.scanStartInterval,
                dateRange: model.libraryDateRange,
                onChange: { model.applyScanSettings() }
            )
            Divider()
            content
        }
        .navigationTitle("Live → Still")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select All") { selection = Set(model.items.map(\.id)) }
                        .disabled(model.items.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Exit select mode but KEEP the selection so it can still be
                    // converted (the tick stays visible in normal mode).
                    Button("Done") { isSelecting = false }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { isSelecting = true }
                        .disabled(model.items.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .alert("Couldn’t convert", isPresented: conversionAlertBinding) {
            Button("OK", role: .cancel) { conversionError = nil }
        } message: {
            Text(conversionError ?? "Try again after checking photo access.")
        }
        .confirmationDialog(
            "Convert \(selection.count) to still?",
            isPresented: $showsConfirm,
            titleVisibility: .visible
        ) {
            Button("Convert \(selection.count)", role: .destructive) { convert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The still keeps the photo and its metadata. The Live Photo’s motion is removed and the original moves to Recently Deleted.")
        }
        .fullScreenCover(isPresented: detailPresented) {
            PhotoDetailPager(
                identifiers: model.items.map(\.id),
                currentID: $detailID,
                selection: optionalSelectionBinding
            )
        }
        .task { if !model.hasScanned { model.scan() } }
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.items.isEmpty {
            Spacer(); ProgressView("Finding Live Photos…"); Spacer()
        } else if model.hasScanned && model.items.isEmpty && !model.isScanning {
            ContentUnavailableView(
                "No Live Photos",
                systemImage: "livephoto",
                description: Text("No convertible Live Photos were found in this range. Loop and Bounce effects aren’t included, and photos unavailable locally can’t be converted.")
            )
        } else {
            grid
        }
    }

    private var detailPresented: Binding<Bool> {
        Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } })
    }

    /// Bridges the non-optional `selection` to the pager's optional binding so
    /// the pager shows a selection tick.
    private var optionalSelectionBinding: Binding<Set<String>?> {
        Binding(get: { selection }, set: { if let new = $0 { selection = new } })
    }

    @State private var didAttemptRestore = false
    @State private var didRestoreScroll = false
    // Indices of grid cells currently on screen; the smallest is the anchor.
    @State private var visibleIndices: Set<Int> = []

    /// Remember the topmost visible cell as the scroll anchor. Skipped until the
    /// initial restore runs so it isn't overwritten before the restore jump.
    private func updateAnchor() {
        guard didRestoreScroll || model.scrollAnchorID == nil else { return }
        guard let topIndex = visibleIndices.min(),
              model.items.indices.contains(topIndex) else { return }
        model.scrollAnchorID = model.items[topIndex].id
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        cell(for: item).id(item.id)
                            // Keep a rolling buffer classified ahead of the row
                            // being viewed, and track the topmost visible cell so
                            // scroll position survives navigation. Tracking the
                            // visible SET is immune to items appending at the end.
                            .onAppear {
                                model.scanMore(currentIndex: index)
                                visibleIndices.insert(index)
                                updateAnchor()
                            }
                            .onDisappear {
                                visibleIndices.remove(index)
                                updateAnchor()
                            }
                    }
                }
                .padding(3)

                // Auto-continue classifying when more remains and the bottom is
                // reached.
                if model.hasMoreToScan {
                    HStack { ProgressView(); Text("Finding more…").font(.caption).foregroundStyle(.secondary) }
                        .padding(.vertical, 8)
                        .onAppear { model.scanMore(currentIndex: model.items.count) }
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
            // On first appear, jump back to the remembered cell; enable anchor
            // tracking only after the restore scroll settles.
            .onAppear {
                guard !didAttemptRestore else { return }
                didAttemptRestore = true
                guard let id = model.scrollAnchorID else { didRestoreScroll = true; return }
                DispatchQueue.main.async {
                    proxy.scrollTo(id, anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { didRestoreScroll = true }
                }
            }
        }
    }

    private func cell(for item: LivePhotoItem) -> some View {
        let selected = selection.contains(item.id)
        return PhotoThumbnail(identifier: item.id, size: 120, fill: true, cornerRadius: 4)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 4).stroke(.tint, lineWidth: 3)
                }
            }
            // Tap the body: in select mode toggle the tick; otherwise open the
            // large zoomable viewer.
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting { toggle(item.id) } else { detailID = item.id }
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
                    Button { toggle(item.id) } label: { tick.contentShape(Circle()) }
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
                        value: [item.id: geo.frame(in: .global)]
                    )
                }
            )
            .accessibilityLabel("Live Photo from \(item.date.formatted(date: .abbreviated, time: .shortened))")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Rubber-band drag-to-select, active only while `isSelecting`. Attached as
    /// a high-priority gesture so it wins over the ScrollView's pan. Applies one
    /// action (decided by the start cell) to every item in the index range
    /// between the anchor and the cell under the finger, and auto-scrolls when
    /// the finger nears the top/bottom edge (Photos-style).
    private var dragSelectGesture: some Gesture {
        // minimumDistance 6 so the paint/scroll decision is made early, before
        // much scrolling happens.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                // Decide once per drag: horizontal/diagonal → paint (lock the
                // ScrollView so it stops); mostly vertical → scroll (no paint).
                if dragIsPaint == nil {
                    let paint = abs(value.translation.width) >= abs(value.translation.height)
                    dragIsPaint = paint
                    if paint { scrollLocked = true }
                }
                guard dragIsPaint == true else { return }

                dragLocation = value.location
                if dragAnchorIndex == nil, let index = itemIndex(at: value.location) {
                    dragAnchorIndex = index
                    dragBaseSelection = selection
                    dragSelects = !selection.contains(model.items[index].id)
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

    /// Apply the drag's action to every item between the anchor and the cell
    /// under `point` (inclusive), from the pre-drag snapshot so backtracking
    /// reverts. No-op if the point isn't over a cell (keeps the last range).
    private func paintRange(to point: CGPoint) {
        guard let anchor = dragAnchorIndex, let base = dragBaseSelection,
              let index = itemIndex(at: point) else { return }
        let lower = min(anchor, index), upper = max(anchor, index)
        var next = base
        for i in lower...upper where model.items.indices.contains(i) {
            let id = model.items[i].id
            if dragSelects { next.insert(id) } else { next.remove(id) }
        }
        selection = next
    }

    /// Set the auto-scroll direction from the finger's distance to the viewport
    /// edges: near the top scroll up, near the bottom scroll down, else stop.
    private func updateAutoScroll(for point: CGPoint) {
        guard viewportFrame.height > 0 else { autoScrollDir = 0; return }
        if point.y < viewportFrame.minY + edgeMargin { autoScrollDir = -1 }
        else if point.y > viewportFrame.maxY - edgeMargin { autoScrollDir = 1 }
        else { autoScrollDir = 0 }
    }

    /// While the finger sits in an edge margin, step the scroll toward the next
    /// off-screen row and keep painting to the finger's cell, so the selection
    /// range extends as new rows scroll into view.
    private func runAutoScroll(proxy: ScrollViewProxy) async {
        while autoScrollDir != 0 {
            let dir = autoScrollDir
            // Scroll to a target a few rows beyond the current visible edge.
            let step = 3
            let targetIndex: Int
            if dir < 0 {
                targetIndex = max(0, (visibleIndices.min() ?? 0) - step)
            } else {
                targetIndex = min(model.items.count - 1, (visibleIndices.max() ?? 0) + step)
            }
            if model.items.indices.contains(targetIndex) {
                withAnimation(.linear(duration: 0.2)) {
                    proxy.scrollTo(model.items[targetIndex].id, anchor: dir < 0 ? .top : .bottom)
                }
                if dir > 0 { model.scanMore(currentIndex: targetIndex) }
                // Extend the paint range to the row we scrolled toward, so the
                // selection keeps growing in the scroll direction rather than
                // snapping back to the (now off-screen) finger cell.
                paintRangeToIndex(targetIndex)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Paint the range from the anchor to an explicit index (used by auto-scroll
    /// where the finger cell is off-screen).
    private func paintRangeToIndex(_ index: Int) {
        guard let anchor = dragAnchorIndex, let base = dragBaseSelection,
              model.items.indices.contains(index) else { return }
        let lower = min(anchor, index), upper = max(anchor, index)
        var next = base
        for i in lower...upper where model.items.indices.contains(i) {
            let id = model.items[i].id
            if dragSelects { next.insert(id) } else { next.remove(id) }
        }
        selection = next
    }

    /// The index in `model.items` of the cell under `point` (global space), or
    /// nil if the point isn't over a known (visible) cell.
    private func itemIndex(at point: CGPoint) -> Int? {
        guard let id = cellFrames.first(where: { $0.value.contains(point) })?.key else { return nil }
        return model.items.firstIndex { $0.id == id }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.items.count) Live Photos")
                        .font(.subheadline.weight(.semibold))
                    Text(selectionHint)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showsConfirm = true
                } label: {
                    if isConverting {
                        ProgressView()
                    } else {
                        Label("Convert \(selection.count)", systemImage: "photo")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || isConverting)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .background(.bar)
    }

    private var selectionHint: String {
        if !selection.isEmpty { return "\(selection.count) selected" }
        return isSelecting ? "Tap or drag to select" : "Tap Select to choose photos"
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private var conversionAlertBinding: Binding<Bool> {
        Binding(get: { conversionError != nil }, set: { if !$0 { conversionError = nil } })
    }

    private func convert() {
        let ids = selection
        guard !ids.isEmpty else { return }
        isConverting = true
        Task { @MainActor in
            do {
                _ = try await model.convertToStill(ids)
                selection.removeAll()
            } catch {
                conversionError = error.localizedDescription
            }
            isConverting = false
        }
    }
}

/// Collects each grid cell's frame (in the grid coordinate space) keyed by item
/// id, so drag-select can hit-test which cell is under the finger.
private struct CellFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
