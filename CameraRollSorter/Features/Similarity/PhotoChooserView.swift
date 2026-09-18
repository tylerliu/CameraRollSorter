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

    init(sequence: PhotoSequence, measuredPairs: [SimilarityPair], library: PhotoLibraryModel) {
        self.sequence = sequence
        self.measuredPairs = measuredPairs
        self.library = library
        _keptIDs = State(initialValue: Set(sequence.photos.map(\.id)))
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
        NavigationStack {
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn’t move photos", isPresented: deletionAlertBinding) {
                Button("OK", role: .cancel) { deletionError = nil }
            } message: {
                Text(deletionError ?? "Try again after checking photo access.")
            }
        }
    }

    private var burstContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Select the photos you want to leave in your library. Unselected photos will be moved to Recently Deleted when you apply the change.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !sequence.photos.isEmpty {
                    let preview = sequence.photos[min(burstPreviewIndex, sequence.photos.count - 1)]
                    PhotoThumbnail(identifier: preview.id, size: 300)
                    Text("Photo \(position(preview.id))")
                        .font(.headline)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(sequence.photos.enumerated()), id: \.element.id) { index, photo in
                            VStack(spacing: 5) {
                                Button {
                                    burstPreviewIndex = index
                                } label: {
                                    PhotoThumbnail(identifier: photo.id, size: 76)
                                        .overlay {
                                            if index == burstPreviewIndex {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(.tint, lineWidth: 3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)

                                Button {
                                    toggle(photo.id)
                                } label: {
                                    Image(systemName: keptIDs.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(keptIDs.contains(photo.id) ? Color.white : Color.secondary, keptIDs.contains(photo.id) ? Color.accentColor : Color.secondary.opacity(0.25))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Photo \(index + 1), \(keptIDs.contains(photo.id) ? "kept" : "marked for deletion")")
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                Text("Tap a thumbnail to inspect it. Use the checkmark to keep or unkeep it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
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
