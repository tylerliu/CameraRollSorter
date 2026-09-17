import SwiftUI

struct SimilarityView: View {
    let sequence: PhotoSequence
    let measuredPairs: [SimilarityPair]

    var body: some View {
        List {
            Section {
                Text("\(sequence.photos.count) photos connected by similarity matches")
                    .font(.headline)
                ScrollView(.horizontal) {
                    LazyHStack {
                        ForEach(Array(sequence.photos.enumerated()), id: \.element.id) { index, photo in
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
                ForEach(measuredPairs) { pair in
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
                Text("Closest connections · \(measuredPairs.count) pairs")
            }
        }
        .navigationTitle("Similar photos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func position(_ id: String) -> Int {
        (sequence.photos.firstIndex { $0.id == id } ?? 0) + 1
    }
}
