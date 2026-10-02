import Photos
import SwiftUI

/// Detail screen for the "Similar photos" category. Lists the measured
/// similarity groups and links each into the chooser. Shares the library model
/// owned by the home screen, so scan state and results stay in sync.
struct SimilarPhotosView: View {
    @Bindable var library: PhotoLibraryModel

    @State private var scrollTracker = ScrollAnchorTracker()
    // Whether the bottom "Scanning more…" row is on screen (the viewer is at
    // the end of the list).
    @State private var endRowVisible = false

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

    /// Tell the scan where the viewer is now: the bottom-most visible row, or
    /// the end of the list while the bottom status row is showing. Scrolling
    /// back up lowers this, so the scan pauses instead of filling a buffer
    /// below rows the viewer has left. When nothing is visible (the list is
    /// going away, or mid-fling) the last real position is kept, since the
    /// list restores to it on return.
    private func reportViewPosition() {
        if endRowVisible {
            library.scanMore(currentIndex: library.groups.count)
        } else if let bottom = scrollTracker.maxVisibleIndex {
            library.scanMore(currentIndex: bottom)
        }
    }

    /// The current number of groups, updated as the scan progresses.
    private var countLabel: String {
        CleanupHomeView.groupCountLabel(library.groups.count)
    }

    /// Pinned scan controls, bound to this list's own window state on the model.
    private var scanControls: some View {
        ScanControlsHeader(
            direction: $library.scanDirectionRaw,
            startEnabled: $library.scanStartEnabled,
            startInterval: $library.scanStartInterval,
            dateRange: library.libraryDateRange,
            onChange: { library.applySettings() },
            onSettle: { library.scheduleWindowCleanup() },
            onCancelCleanup: { library.cancelWindowCleanup() }
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
                // progress, which is meaningless for a partial scan.
                if library.isScanning || library.hasScanned || !library.groups.isEmpty {
                    HStack(spacing: 6) {
                        Text(countLabel)
                        if library.hasMoreToScan {
                            Text("&")
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                            scrollTracker.onRowAppear(index)
                            updateAnchor()
                            reportViewPosition()
                        }
                        .onDisappear {
                            scrollTracker.onRowDisappear(index)
                            updateAnchor()
                            reportViewPosition()
                        }
                    }
                }

                // Bottom status row: when more remains, show a spinner and keep
                // scanning automatically — reaching the bottom resumes a paused
                // scan, so there's no manual "scan more" step.
                if library.hasMoreToScan {
                    HStack { ProgressView(); Text("Scanning more…").font(.caption).foregroundStyle(.secondary) }
                        .onAppear { endRowVisible = true; reportViewPosition() }
                        .onDisappear { endRowVisible = false; reportViewPosition() }
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
