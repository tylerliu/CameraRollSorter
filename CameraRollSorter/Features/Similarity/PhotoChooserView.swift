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
            burstContent
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationTitle("Choose photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
        .sheet(isPresented: infoSheetBinding) {
            if let infoPhotoID {
                PhotoInfoView(identifier: infoPhotoID)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
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

    private var burstContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                if !orderedPhotos.isEmpty {
                    let preview = orderedPhotos[min(burstPreviewIndex, orderedPhotos.count - 1)]
                    let kept = keptIDs.contains(preview.id)

                    ZoomablePhotoView(identifier: preview.id, isZoomed: $isPreviewZoomed, onTap: { toggle(preview.id) }) {
                        infoPhotoID = preview.id
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
                        Label("Suggested best shot", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Pinch to zoom · tap to toggle · swipe up for info")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func filmstrip(width: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 7) {
                ForEach(Array(orderedPhotos.enumerated()), id: \.element.id) { index, photo in
                    VStack(spacing: 4) {
                        PhotoThumbnail(identifier: photo.id, size: 54)
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
        .contentMargins(.horizontal, max(0, (width - 54) / 2), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $centeredPhotoID, anchor: .center)
        .frame(height: 82)
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
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(keptIDs.count) of \(orderedPhotos.count) kept")
                        .font(.subheadline.weight(.semibold))
                    if markedForDeletion.isEmpty {
                        Text("No photos marked for deletion")
                    } else {
                        Text("\(markedForDeletion.count) will go to Recently Deleted")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    deleteMarkedPhotos()
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Label("Delete \(markedForDeletion.count)", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(markedForDeletion.isEmpty || isDeleting)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
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
