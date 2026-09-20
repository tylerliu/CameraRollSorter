import Photos
import SwiftUI

/// Detail screen for the "Similar photos" category. Lists the measured
/// similarity groups and links each into the chooser. Shares the library model
/// owned by the home screen, so scan state and results stay in sync.
struct SimilarPhotosView: View {
    let library: PhotoLibraryModel

    /// "12 groups" once fully scanned, or "12 groups & more" while photos
    /// remain to be scanned.
    private var countLabel: String {
        let n = library.groups.count
        let unit = n == 1 ? "group" : "groups"
        return library.hasMoreToScan ? "\(n) \(unit) & more" : "\(n) \(unit)"
    }

    var body: some View {
        List {
            Section {
                Text("Similarity distance ≤ \(library.threshold, format: .number.precision(.fractionLength(2))) · change in review settings")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = library.analysisError { Text(error).foregroundStyle(.secondary) }
            }
            Section {
                // Count is shown as soon as scanning starts — no "X of N"
                // progress, which is meaningless for a partial scan. "0 groups
                // & more" is the honest starting state.
                if library.isScanning || library.hasScanned || !library.groups.isEmpty {
                    Text(countLabel).font(.caption).foregroundStyle(.secondary)
                }
                if library.hasScanned || !library.groups.isEmpty {
                    if library.hasScanned && library.groups.isEmpty && !library.isScanning {
                        ContentUnavailableView(
                            "No groups found",
                            systemImage: "photo.stack",
                            description: Text(library.analysisError == nil
                                ? "No measured matches met the distance threshold. Try adjusting it in settings. Photos unavailable locally cannot be matched."
                                : "Similarity analysis did not finish. Pull to refresh to retry.")
                        )
                    }
                    ForEach(Array(library.groups.enumerated()), id: \.element.id) { index, group in
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
                        // Load more when the list nears its end.
                        .onAppear {
                            if index >= library.groups.count - 3 { library.scanMore() }
                        }
                    }
                }

                // Bottom status row: spinner while a batch runs, or a tap to
                // continue when paused with more to scan.
                if library.hasMoreToScan {
                    if library.isScanningBatch {
                        HStack { ProgressView(); Text("Scanning more…").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Button("Scan more") { library.scanMore() }
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Similar photos")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { library.refresh() }
    }
}
