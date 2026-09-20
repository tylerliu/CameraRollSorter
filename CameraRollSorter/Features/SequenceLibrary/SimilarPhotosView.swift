import Photos
import SwiftUI

/// Detail screen for the "Similar photos" category. Lists the measured
/// similarity groups and links each into the chooser. Shares the library model
/// owned by the home screen, so scan state and results stay in sync.
struct SimilarPhotosView: View {
    @Bindable var library: PhotoLibraryModel

    @State private var didAttemptRestore = false
    @State private var didRestoreScroll = false
    // Indices of group rows currently on screen. The topmost (smallest) one is
    // remembered as the scroll anchor. A Set is used so the scan appending rows
    // at the bottom never changes which row is topmost-visible.
    @State private var visibleIndices: Set<Int> = []

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

    /// Remember the topmost visible group as the scroll anchor. Skipped until
    /// the initial restore has run, so navigating back doesn't overwrite the
    /// saved anchor with the (top-of-list) rows shown before the restore jump.
    private func updateAnchor() {
        guard didRestoreScroll || library.scrollAnchorID == nil else { return }
        guard let topIndex = visibleIndices.min(),
              library.groups.indices.contains(topIndex) else { return }
        library.scrollAnchorID = library.groups[topIndex].id
    }

    /// "12 groups" once fully scanned, or "12 groups & more" while photos
    /// remain to be scanned.
    private var countLabel: String {
        let n = library.groups.count
        let unit = n == 1 ? "group" : "groups"
        return library.hasMoreToScan ? "\(n) \(unit) & more" : "\(n) \(unit)"
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
                            PhotoChooserView(sequence: group, measuredPairs: library.scores(for: group), library: library)
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
                        // the topmost one across navigation. Tracking the visible
                        // SET (not last-appeared) is immune to the scan appending
                        // new rows at the bottom.
                        .onAppear {
                            library.scanMore(currentIndex: index)
                            visibleIndices.insert(index)
                            updateAnchor()
                        }
                        .onDisappear {
                            visibleIndices.remove(index)
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
        // On first appear of this view instance, jump back to the remembered
        // group (a List won't auto-restore an unmaterialized row). Enable anchor
        // tracking only AFTER the restore scroll completes, so the top-of-list
        // rows shown pre-jump don't overwrite the saved anchor.
        .onAppear {
            guard !didAttemptRestore else { return }
            didAttemptRestore = true
            guard let id = library.scrollAnchorID else { didRestoreScroll = true; return }
            DispatchQueue.main.async {
                proxy.scrollTo(id, anchor: .top)
                // Let the scroll settle before re-enabling tracking.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    didRestoreScroll = true
                }
            }
        }
        }
    }
}
