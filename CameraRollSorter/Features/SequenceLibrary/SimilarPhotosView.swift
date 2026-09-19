import Photos
import SwiftUI

/// Detail screen for the "Similar photos" category. Lists the measured
/// similarity groups and links each into the chooser. Shares the library model
/// owned by the home screen, so scan state and results stay in sync.
struct SimilarPhotosView: View {
    let library: PhotoLibraryModel

    var body: some View {
        List {
            Section {
                Text("Similarity distance ≤ \(library.threshold, format: .number.precision(.fractionLength(2))) · change in review settings")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = library.analysisError { Text(error).foregroundStyle(.secondary) }
            }
            Section {
                if library.isScanning {
                    ProgressView(library.progress)
                }
                if library.hasScanned || !library.groups.isEmpty {
                    if !library.summary.isEmpty {
                        Text(library.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    if library.hasScanned && library.groups.isEmpty {
                        ContentUnavailableView(
                            "No groups found",
                            systemImage: "photo.stack",
                            description: Text(library.analysisError == nil
                                ? "No measured matches met the distance threshold. Try adjusting it in settings. Photos unavailable locally cannot be matched."
                                : "Similarity analysis did not finish. Pull to refresh to retry.")
                        )
                    }
                    ForEach(library.groups) { group in
                        NavigationLink {
                            PhotoChooserView(sequence: group, measuredPairs: library.scores(for: group), library: library)
                        } label: {
                            HStack {
                                PhotoThumbnail(identifier: group.photos[0].id, size: 72)
                                VStack(alignment: .leading) {
                                    Text("\(group.photos.count) similar photos")
                                    Text(group.photos[0].date, format: .dateTime.month().day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("Choose photos to keep").font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Similar photos")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { library.refresh() }
    }
}
