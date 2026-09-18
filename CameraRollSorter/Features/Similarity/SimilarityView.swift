import SwiftUI

struct SimilarityView: View {
    let sequence: PhotoSequence
    let measuredPairs: [SimilarityPair]
    let library: PhotoLibraryModel
    @State private var showsChooser = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var activeSequence: PhotoSequence? {
        let originalIDs = Set(sequence.photos.map(\.id))
        return library.groups
            .filter { group in group.photos.contains { originalIDs.contains($0.id) } }
            .max { lhs, rhs in
                overlapCount(lhs, with: originalIDs) < overlapCount(rhs, with: originalIDs)
            }
    }

    private func overlapCount(_ group: PhotoSequence, with ids: Set<String>) -> Int {
        group.photos.reduce(into: 0) { count, photo in
            if ids.contains(photo.id) { count += 1 }
        }
    }

    var body: some View {
        List {
            Section {
                Text("\(displayedSequence.photos.count) photos connected by similarity matches")
                    .font(.headline)
                ScrollView(.horizontal) {
                    LazyHStack {
                        ForEach(Array(displayedSequence.photos.enumerated()), id: \.element.id) { index, photo in
                            VStack {
                                PhotoThumbnail(identifier: photo.id)
                                Text("Photo \(index + 1)").font(.caption)
                            }
                        }
                    }
                }
                .frame(height: 135)
                Text("Any photo can join through a match with another member. Capture time only limits which pairs are tested.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("The closest measured links needed to connect all photos, without redundant loops. Lower Vision distance means more similar; these are not percentage scores.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(displayedPairs) { pair in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            PhotoThumbnail(identifier: pair.first)
                            PhotoThumbnail(identifier: pair.second)
                        }
                        Text("Photos \(position(pair.first)) and \(position(pair.second))")
                            .font(.headline)
                        Text(pair.distance, format: .number.precision(.fractionLength(4)))
                            .font(.title2.bold()).monospacedDigit()
                        Text("Vision distance · lower is closer")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Closest connections · \(displayedPairs.count) pairs")
            }
        }
        .navigationTitle("Similar photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsChooser = true
                } label: {
                    Image(systemName: colorScheme == .dark ? "photo.fill" : "photo")
                        .overlay {
                            GeometryReader { geometry in
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: 0))
                                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                                }
                                .stroke(.background, lineWidth: 4)
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: 0))
                                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                                }
                                .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            }
                        }
                }
                .accessibilityLabel("Choose photos to delete")
            }
        }
        .sheet(isPresented: $showsChooser, onDismiss: dismissIfGroupIsGone) {
            PhotoChooserView(sequence: displayedSequence, measuredPairs: displayedPairs, library: library)
        }
        .onChange(of: library.hasScanned) { _, hasScanned in
            if hasScanned && !showsChooser { dismissIfGroupIsGone() }
        }
    }

    private func dismissIfGroupIsGone() {
        if library.hasScanned && activeSequence == nil { dismiss() }
    }

    private var displayedSequence: PhotoSequence { activeSequence ?? sequence }

    private var displayedPairs: [SimilarityPair] {
        guard let activeSequence else { return measuredPairs }
        return library.scores(for: activeSequence)
    }

    private func position(_ id: String) -> Int {
        (displayedSequence.photos.firstIndex { $0.id == id } ?? 0) + 1
    }
}
