import Photos
import SwiftUI

/// Detail screen for the "Similar photos" category. Lists the measured
/// similarity groups and links each into the chooser. Shares the library model
/// owned by the home screen, so scan state and results stay in sync.
struct SimilarPhotosView: View {
    @Bindable var library: PhotoLibraryModel

    @State private var scrollTracker = ScrollAnchorTracker()

    /// Row date label: month/day and time, adding the year only when the photo
    /// isn't from the current year.
    private static func rowDate(_ date: Date) -> String {
        let cal = Calendar.current
        let base = Date.FormatStyle.dateTime.month().day().hour().minute()
        let format = cal.component(.year, from: date) == cal.component(.year, from: Date())
            ? base
            : base.year()
        return date.formatted(format)
    }

    /// Save the topmost visible group as the scroll anchor on the model. Indexes
    /// directly (no per-event allocation of the full id array).
    private func updateAnchor() {
        guard let top = scrollTracker.topVisibleIndexForAnchor, library.groups.indices.contains(top) else { return }
        library.scrollAnchorID = library.groups[top].id
    }

    /// "12 groups" once fully scanned, or "12 groups & more" while photos
    /// remain to be scanned.
    private var countLabel: String {
        CleanupHomeView.groupCountLabel(library.groups.count, more: library.hasMoreToScan)
    }

    /// Pinned scan controls, bound to this list's own window state on the model.
    private var scanControls: some View {
        ScanControlsHeader(
            direction: $library.scanDirectionRaw,
            startEnabled: $library.scanStartEnabled,
            startInterval: $library.scanStartInterval,
            dateRange: library.libraryDateRange,
            onChange: { library.applySettings() }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            scanControls
            Divider()
            list
        }
        .navigationTitle("Similar photos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var list: some View {
        ScrollViewReader { proxy in
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
                            PhotoChooserView(sequence: group, library: library)
                        } label: {
                            HStack {
                                PhotoThumbnail(identifier: group.photos[0].id, size: 72)
                                VStack(alignment: .leading) {
                                    Text("\(group.photos.count) similar photos")
                                    Text(Self.rowDate(group.photos[0].date))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("Choose photos to keep").font(.caption)
                                }
                            }
                        }
                        .id(group.id)
                        // Keep a rolling buffer scanned ahead of the viewed row,
                        // and track which rows are on screen so we can remember
                        // the topmost one across navigation.
                        .onAppear {
                            library.scanMore(currentIndex: index)
                            scrollTracker.onRowAppear(index)
                            updateAnchor()
                        }
                        .onDisappear {
                            scrollTracker.onRowDisappear(index)
                            updateAnchor()
                        }
                    }
                }

                // Bottom status row: when more remains, show a spinner and keep
                // scanning automatically — reaching the bottom resumes a paused
                // scan, so there's no manual "scan more" step.
                if library.hasMoreToScan {
                    HStack { ProgressView(); Text("Scanning more…").font(.caption).foregroundStyle(.secondary) }
                        .onAppear { library.scanMore(currentIndex: library.groups.count) }
                }
            }
        }
        .refreshable { library.refresh() }
        .onAppear {
            scrollTracker.restore(library.scrollAnchorID, proxy: proxy)
            library.setListActive(true)
        }
        .onDisappear { library.setListActive(false) }
        }
    }
}
