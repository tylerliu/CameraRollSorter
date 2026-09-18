import Photos
import SwiftUI

struct PhotoChooserView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case burst = "Keep list"
        case pairs = "Pair review"

        var id: Self { self }
    }

    let sequence: PhotoSequence
    let measuredPairs: [SimilarityPair]
    let library: PhotoLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.burst
    @State private var keptIDs: Set<String>
    @State private var burstPreviewIndex = 0
    @State private var pairIndex = 0
    @State private var isDeleting = false
    @State private var deletionError: String?
    @State private var centeredPhotoID: String?
    @State private var infoPhotoID: String?
    @State private var isPreviewZoomed = false

    init(sequence: PhotoSequence, measuredPairs: [SimilarityPair], library: PhotoLibraryModel) {
        self.sequence = sequence
        self.measuredPairs = measuredPairs
        self.library = library
        _keptIDs = State(initialValue: Set(sequence.photos.map(\.id)))
        // Set after the filmstrip's first layout so scrollPosition performs an
        // actual initial scroll instead of treating the value as already applied.
        _centeredPhotoID = State(initialValue: nil)
    }

    private var orderedPairs: [SimilarityPair] {
        measuredPairs.sorted {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.first != $1.first { return $0.first < $1.first }
            return $0.second < $1.second
        }
    }

    private var allIDs: Set<String> { Set(sequence.photos.map(\.id)) }
    private var markedForDeletion: Set<String> { allIDs.subtracting(keptIDs) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Review mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 12)

            Group {
                switch mode {
                case .burst:
                    burstContent
                case .pairs:
                    pairContent
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationTitle("Choose photos")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t move photos", isPresented: deletionAlertBinding) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "Try again after checking photo access.")
        }
        .sheet(isPresented: infoSheetBinding) {
            if let infoPhotoID { PhotoInfoView(identifier: infoPhotoID) }
        }
    }

    private var burstContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                if !sequence.photos.isEmpty {
                    let preview = sequence.photos[min(burstPreviewIndex, sequence.photos.count - 1)]
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

                    Text("Pinch to zoom · tap badge to toggle · swipe up for info")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func filmstrip(width: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 7) {
                ForEach(Array(sequence.photos.enumerated()), id: \.element.id) { index, photo in
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
        .frame(height: 68)
        .task(id: sequence.id) {
            guard centeredPhotoID == nil, let firstID = sequence.photos.first?.id else { return }
            await Task.yield()
            centeredPhotoID = firstID
        }
        .onChange(of: centeredPhotoID) { _, identifier in
            guard let identifier,
                  let index = sequence.photos.firstIndex(where: { $0.id == identifier }) else { return }
            burstPreviewIndex = index
        }
        .onChange(of: burstPreviewIndex) { _, index in
            guard sequence.photos.indices.contains(index) else { return }
            centeredPhotoID = sequence.photos[index].id
        }
        .accessibilityLabel("Photo filmstrip")
    }

    @ViewBuilder
    private var pairContent: some View {
        if orderedPairs.isEmpty {
            ContentUnavailableView("No measured pairs", systemImage: "arrow.left.arrow.right", description: Text("This group has no stored similarity connections to review."))
        } else if pairIndex >= orderedPairs.count {
            ContentUnavailableView {
                Label("Pair review complete", systemImage: "checkmark.circle")
            } description: {
                Text("You reviewed all \(orderedPairs.count) connections. You can still change the keep list below or review the pairs again.")
            } actions: {
                Button("Review pairs again") { pairIndex = 0 }
                    .buttonStyle(.bordered)
            }
        } else {
            let pair = orderedPairs[pairIndex]
            ScrollView {
                VStack(spacing: 18) {
                    Text("Pair \(pairIndex + 1) of \(orderedPairs.count)")
                        .font(.headline)
                    Text("Mark a photo for deletion below, or skip to keep both. Apply deletions using the button at the bottom.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 14) {
                        pairCard(identifier: pair.first, title: "Photo \(position(pair.first))") {
                            choose(.second, for: pair)
                        }
                        pairCard(identifier: pair.second, title: "Photo \(position(pair.second))") {
                            choose(.first, for: pair)
                        }
                    }

                    Text("Vision distance \(pair.distance, format: .number.precision(.fractionLength(4))) · lower is closer")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Previous") { pairIndex = max(0, pairIndex - 1) }
                            .disabled(pairIndex == 0)
                        Spacer()
                        Button("Skip") { choose(.both, for: pair) }
                    }
                    .font(.subheadline)
                }
                .padding()
            }
        }
    }

    private func pairCard(identifier: String, title: String, onDelete: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            PhotoThumbnail(identifier: identifier, size: 145)
            Text(title).font(.caption)
            Label(keptIDs.contains(identifier) ? "Kept" : "Marked for deletion", systemImage: keptIDs.contains(identifier) ? "checkmark" : "trash")
                .font(.caption2)
                .foregroundStyle(keptIDs.contains(identifier) ? Color.accentColor : Color.secondary)
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityLabel("Mark \(title) for deletion")
        }
        .frame(maxWidth: .infinity)
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(keptIDs.count) of \(sequence.photos.count) kept")
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

    private enum PairChoice { case first, second, both }

    private func choose(_ choice: PairChoice, for pair: SimilarityPair) {
        switch choice {
        case .first:
            keptIDs.insert(pair.first)
            keptIDs.remove(pair.second)
        case .second:
            keptIDs.remove(pair.first)
            keptIDs.insert(pair.second)
        case .both:
            keptIDs.insert(pair.first)
            keptIDs.insert(pair.second)
        }
        pairIndex = min(orderedPairs.count, pairIndex + 1)
    }

    private func toggle(_ identifier: String) {
        if keptIDs.contains(identifier) {
            keptIDs.remove(identifier)
        } else {
            keptIDs.insert(identifier)
        }
    }

    private func position(_ identifier: String) -> Int {
        (sequence.photos.firstIndex { $0.id == identifier } ?? 0) + 1
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
                deletionError = error.localizedDescription
            }
        }
    }
}
