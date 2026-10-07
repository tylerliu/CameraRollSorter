import Photos
import SwiftUI

struct PhotoChooserView: View {
    let sequence: PhotoSequence
    let library: PhotoLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var keptIDs: Set<String>
    @State private var burstPreviewIndex = 0
    @State private var isDeleting = false
    @State private var deletionError: String?
    @State private var centeredPhotoID: String?
    @State private var infoPhotoID: String?
    @State private var isPreviewZoomed = false
    @State private var showsCompositionGrid = false
    #if os(macOS)
    @State private var macViewerWidth: CGFloat = 800
    @State private var macZoomScale: CGFloat = 1
    @State private var filmstripDragStartIndex: Int?
    #endif

    /// Photos ordered so the most-similar shots are adjacent (spine ordering),
    /// making filmstrip scrubbing act as flicker comparison. Computed once in
    /// `.task` (NOT in init) so building this view as a NavigationLink
    /// destination stays cheap and never lags the list while scrolling. Starts
    /// as the group's own order until the ordering pass completes.
    @State private var orderedPhotos: [TimedPhoto]
    @State private var didOrder = false

    // Aesthetics-based "best photo" hint. Purely a visual suggestion — it never
    // changes the keep list, deletion, ordering, or grouping. Runs on its own
    // actor so it doesn't block the library's similarity analysis.
    @State private var bestIDs: Set<String> = []
    private let aestheticsScorer = AestheticsScorer()

    init(sequence: PhotoSequence, library: PhotoLibraryModel) {
        self.sequence = sequence
        self.library = library
        _keptIDs = State(initialValue: Set(sequence.photos.map(\.id)))
        // Cheap init: show the group's own order immediately; the (expensive)
        // similarity ordering runs in `.task` after the view appears.
        _orderedPhotos = State(initialValue: sequence.photos)
        // Set after the filmstrip's first layout so scrollPosition performs an
        // actual initial scroll instead of treating the value as already applied.
        _centeredPhotoID = State(initialValue: nil)
    }

    private var allIDs: Set<String> { Set(orderedPhotos.map(\.id)) }
    private var markedForDeletion: Set<String> { allIDs.subtracting(keptIDs) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                burstContent
                #if os(macOS)
                if infoPhotoID != nil, let id = previewID {
                    Divider()
                    MacPhotoInfoPane(identifier: id) { infoPhotoID = nil }
                }
                #endif
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationTitle("Choose photos")
        .inlineNavigationTitle()
        #if os(macOS)
        .toolbar(removing: .title)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { macViewerWidth = $0 }
        #endif
        .toolbar {
            #if os(macOS)
            macToolbar
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            }
            #endif
            ToolbarItem(placement: .platformTrailing) {
                Button("Composition grid", systemImage: "grid") { showsCompositionGrid.toggle() }
                    .labelStyle(.iconOnly)
                    .tint(showsCompositionGrid ? Color.accentColor : Color.primary)
                    .accessibilityValue(showsCompositionGrid ? "On" : "Off")
                    .help("Toggle composition grid")
            }
            ToolbarItem(placement: .platformTrailing) {
                // One tap flips the whole group: if nothing's marked yet, mark
                // all for deletion; otherwise reset to keep everything.
                if markedForDeletion.isEmpty {
                    Button("Mark All") { keptIDs.removeAll() }
                } else {
                    Button("Keep All") { keptIDs = allIDs }
                }
            }
        }
        .alert("Couldn’t move photos", isPresented: deletionAlertBinding) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "Try again after checking photo access.")
        }
        #if os(iOS)
        .sheet(isPresented: infoSheetBinding) {
            if let infoPhotoID {
                PhotoInfoView(identifier: infoPhotoID)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        #endif
        .task(id: sequence.id) {
            // Compute the flicker-comparison ordering here (not in init) so the
            // list stays smooth: building this view as a NavigationLink
            // destination must be cheap. The MST/spine work runs off the main
            // actor, then the ordered result is applied.
            guard !didOrder else { return }
            let photos = sequence.photos
            let pairs = library.scores(for: sequence)
            let threshold = library.threshold
            let ordered = await Task.detached(priority: .userInitiated) {
                SimilarityGrouping.similarityOrder(photos: photos, pairs: pairs, threshold: threshold)
            }.value
            guard !Task.isCancelled else { return }
            orderedPhotos = ordered
            didOrder = true
        }
        .task(id: sequence.id) {
            // Score the open group's photos for a best-shot suggestion. Runs on
            // a dedicated actor, independent of the library similarity scan.
            let ids = sequence.photos.map(\.id)
            let result = await aestheticsScorer.score(identifiers: ids)
            guard !Task.isCancelled else { return }
            bestIDs = BestPhotoSelector.bestIDs(from: result)
        }
    }

    #if os(macOS)
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        MacViewerTitleItem(title: "Choose photos", windowWidth: macViewerWidth)
        MacPhotoZoomItem(scale: $macZoomScale)
        ToolbarItemGroup(placement: .automatic) {
            Button("Previous", systemImage: "chevron.left") { movePreview(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(burstPreviewIndex == 0)
                .labelStyle(.iconOnly)
                .help("Previous photo")
            Text("\(orderedPhotos.isEmpty ? 0 : burstPreviewIndex + 1) of \(orderedPhotos.count)")
            Button("Next", systemImage: "chevron.right") { movePreview(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(burstPreviewIndex >= orderedPhotos.count - 1)
                .labelStyle(.iconOnly)
                .help("Next photo")
            Button("Info", systemImage: "info.circle") {
                infoPhotoID = infoPhotoID == nil ? previewID : nil
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(previewID == nil)
            .labelStyle(.iconOnly)
            .help("Photo info")
            Button(previewID.map { keptIDs.contains($0) } == true ? "Kept" : "Keep",
                   systemImage: previewID.map { keptIDs.contains($0) } == true ? "checkmark.circle.fill" : "circle") {
                if let id = previewID { toggle(id) }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(previewID == nil)
            .labelStyle(.iconOnly)
            .help(previewID.map { keptIDs.contains($0) } == true ? "Mark for deletion" : "Keep photo")
        }
    }
    #endif

    private var previewID: String? {
        guard orderedPhotos.indices.contains(burstPreviewIndex) else { return nil }
        return orderedPhotos[burstPreviewIndex].id
    }

    private func movePreview(_ offset: Int) {
        let index = burstPreviewIndex + offset
        guard orderedPhotos.indices.contains(index) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            burstPreviewIndex = index
            centeredPhotoID = orderedPhotos[index].id
        }
    }

    private var burstContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                if !orderedPhotos.isEmpty {
                    let preview = orderedPhotos[min(burstPreviewIndex, orderedPhotos.count - 1)]
                    let kept = keptIDs.contains(preview.id)

                    Group {
                        #if os(iOS)
                        ZoomablePhotoView(identifier: preview.id, isZoomed: $isPreviewZoomed, showsCompositionGrid: showsCompositionGrid, onTap: { toggle(preview.id) }) {
                            infoPhotoID = preview.id
                        }
                        #else
                        MacPhotoPager(identifiers: orderedPhotos.map(\.id),
                                      currentIndex: $burstPreviewIndex, zoomScale: $macZoomScale, onClick: toggle,
                                      animatesIndexChanges: false, showsCompositionGrid: showsCompositionGrid)
                        #endif
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(isPreviewZoomed ? 1 : 0)
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            toggle(preview.id)
                        } label: {
                            ZStack {
                                // White backing so the icon reads against any photo.
                                Circle()
                                    .fill(.white)
                                    .frame(width: 28, height: 28)
                                Image(systemName: kept ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(kept ? Color.accentColor : Color.red)
                            }
                        }
                        .accessibilityLabel(kept ? "Kept" : "Not kept")
                        .accessibilityHint("Toggles whether this photo will be kept")
                        // Inset slightly from the corner so it clears the rounded clip.
                        .padding(14)
                    }

                    filmstrip(width: geometry.size.width)

                    if bestIDs.contains(preview.id) {
                        Label("Suggested best photo", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Group {
                            #if os(iOS)
                            Text("Pinch to zoom · tap to toggle · swipe up for info")
                            #else
                            Text("Click to toggle")
                            #endif
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var filmstripThumbnailSize: CGFloat {
        #if os(macOS)
        90
        #else
        54
        #endif
    }

    private func filmstrip(width: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 7) {
                ForEach(Array(orderedPhotos.enumerated()), id: \.element.id) { index, photo in
                    VStack(spacing: 4) {
                        PhotoThumbnail(identifier: photo.id, size: filmstripThumbnailSize)
                            .overlay(alignment: .bottomTrailing) {
                                ZStack {
                                    Circle()
                                        .fill(.white)
                                        .frame(width: 14, height: 14)
                                    Image(systemName: keptIDs.contains(photo.id) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                        .foregroundStyle(keptIDs.contains(photo.id) ? Color.accentColor : Color.red)
                                }
                                .padding(3)
                            }
                            .overlay {
                                if index == burstPreviewIndex {
                                    RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3)
                                }
                            }

                        // Suggested-best dot sits BELOW the thumbnail, in its own
                        // reserved row (mirrors Photos burst selection). Visual
                        // hint only; does not affect keep/delete state.
                        Circle()
                            .fill(bestIDs.contains(photo.id) ? Color.primary : Color.clear)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(bestIDs.contains(photo.id) ? "Suggested best photo" : "")
                    }
                    .id(photo.id)
                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                        content.scaleEffect(phase.isIdentity ? 1.08 : 0.9)
                    }
                    .onTapGesture {
                        centeredPhotoID = photo.id
                        burstPreviewIndex = index
                    }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, max(0, (width - filmstripThumbnailSize) / 2), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $centeredPhotoID, anchor: .center)
        .frame(height: filmstripThumbnailSize + 28)
        #if os(macOS)
        .highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if filmstripDragStartIndex == nil {
                        filmstripDragStartIndex = burstPreviewIndex
                    }
                    let step = Int((-value.translation.width / (filmstripThumbnailSize + 7)).rounded())
                    let index = min(max(0, (filmstripDragStartIndex ?? burstPreviewIndex) + step),
                                    orderedPhotos.count - 1)
                    guard orderedPhotos.indices.contains(index) else { return }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        burstPreviewIndex = index
                        centeredPhotoID = orderedPhotos[index].id
                    }
                }
                .onEnded { _ in filmstripDragStartIndex = nil }
        )
        #endif
        .task(id: sequence.id) {
            guard centeredPhotoID == nil, let firstID = orderedPhotos.first?.id else { return }
            await Task.yield()
            centeredPhotoID = firstID
        }
        .onChange(of: centeredPhotoID) { _, identifier in
            guard let identifier,
                  let index = orderedPhotos.firstIndex(where: { $0.id == identifier }) else { return }
            burstPreviewIndex = index
        }
        .onChange(of: burstPreviewIndex) { _, index in
            guard orderedPhotos.indices.contains(index) else { return }
            centeredPhotoID = orderedPhotos[index].id
        }
        .accessibilityLabel("Photo filmstrip")
    }

    private var actionBar: some View {
        VStack(spacing: PhotoActionBarLayout.spacing) {
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(keptIDs.count) of \(orderedPhotos.count) kept")
                        .font(PhotoActionBarLayout.titleFont)
                    if markedForDeletion.isEmpty {
                        Text("No photos marked for deletion")
                    } else {
                        Text("\(markedForDeletion.count) will go to Recently Deleted")
                    }
                }
                .font(PhotoActionBarLayout.detailFont)
                .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    deleteMarkedPhotos()
                } label: {
                    Group {
                        if isDeleting {
                            ProgressView()
                        } else {
                            Label("Delete \(markedForDeletion.count)", systemImage: "trash")
                        }
                    }
                    .photoActionButtonLabelSizing()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                #if os(macOS)
                .keyboardShortcut(.delete, modifiers: [])
                #endif
                .disabled(markedForDeletion.isEmpty || isDeleting)
            }
            .photoActionBarSizing()
        }
        .background(.bar)
    }

    private func toggle(_ identifier: String) {
        if keptIDs.contains(identifier) {
            keptIDs.remove(identifier)
        } else {
            keptIDs.insert(identifier)
        }
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )
    }

    private var infoSheetBinding: Binding<Bool> {
        Binding(
            get: { infoPhotoID != nil },
            set: { if !$0 { infoPhotoID = nil } }
        )
    }

    private func deleteMarkedPhotos() {
        let ids = markedForDeletion
        guard !ids.isEmpty else { return }
        isDeleting = true
        Task { @MainActor in
            do {
                _ = try await library.deletePhotos(ids)
                isDeleting = false
                dismiss()
            } catch {
                isDeleting = false
                // Tapping Cancel on the system delete prompt isn't an error.
                if !PhotoLibraryErrors.isUserCancelled(error) {
                    deletionError = error.localizedDescription
                }
            }
        }
    }
}
