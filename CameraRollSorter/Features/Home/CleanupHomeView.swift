import Photos
import SwiftUI

/// Top-level "categories" home. Owns photo-access UI and the shared privacy
/// messaging, and lists each cleanup category as a row that pushes its own
/// review screen. New categories (Live → Still, Blurry) slot in as more rows.
struct CleanupHomeView: View {
    @State private var library = PhotoLibraryModel()
    @State private var liveToStill = LiveToStillModel()
    @State private var showsSettings = false
    @State private var showsLimitedPicker = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if library.canRead { categories }
                else { permission }
            }
            .navigationTitle("Camera Roll Sorter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Review settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                }
            }
            .sheet(isPresented: $showsSettings, onDismiss: library.applySettings) { ReviewSettingsView() }
            .background {
                LimitedLibraryPicker(isPresented: $showsLimitedPicker) {
                    // Selecting more photos under limited access is an add,
                    // handled incrementally — not a full rescan.
                    Task { await library.syncLibrary() }
                }
                .frame(width: 0, height: 0)
            }
        }
        .task {
            library.refresh()
            liveToStill.scan()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await library.syncLibrary() }
                liveToStill.scan()
            }
        }
    }

    private var categories: some View {
        List {
            accessSection

            Section("Cleanup") {
                NavigationLink {
                    SimilarPhotosView(library: library)
                } label: {
                    CategoryRow(
                        title: "Similar photos",
                        systemImage: "photo.stack",
                        detail: similarDetail
                    )
                }
                NavigationLink {
                    LiveToStillView(model: liveToStill)
                } label: {
                    CategoryRow(
                        title: "Live → Still",
                        systemImage: "livephoto",
                        detail: liveToStillDetail
                    )
                }
            }
        }
    }

    /// Subtitle for the Live → Still row: scan progress or a live count with
    /// "& more" while classification is still in progress.
    private var liveToStillDetail: CategoryRow.Detail {
        if liveToStill.isScanning && liveToStill.items.isEmpty {
            return .progress("")
        }
        if !liveToStill.hasScanned && liveToStill.items.isEmpty {
            return .text("Tap to scan")
        }
        if liveToStill.hasScanned && liveToStill.items.isEmpty && !liveToStill.hasMoreToScan {
            return .text("None found")
        }
        let unit = liveToStill.items.count == 1 ? "photo" : "photos"
        let suffix = liveToStill.hasMoreToScan ? " & more" : ""
        return .text("\(liveToStill.items.count) \(unit)\(suffix)")
    }

    /// Subtitle for the Similar photos row: scan progress or a result summary.
    private var similarDetail: CategoryRow.Detail {
        // Before any scan: prompt to scan. Otherwise a live count with "& more"
        // while photos remain — no "X of N" progress, meaningless for partial.
        if !library.isScanning && !library.hasScanned && library.groups.isEmpty {
            return .text("Tap to scan")
        }
        if library.hasScanned && library.groups.isEmpty && !library.hasMoreToScan {
            return .text("No groups found")
        }
        let unit = library.groups.count == 1 ? "group" : "groups"
        let suffix = library.hasMoreToScan ? " & more" : ""
        return .text("\(library.groups.count) \(unit)\(suffix)")
    }

    private var accessSection: some View {
        Section {
            Label(
                library.authorization == .limited ? "Limited photo access" : "Full photo access",
                systemImage: "photo.on.rectangle"
            )
            if library.authorization == .limited {
                Text("Results include only the photos you have allowed.")
                Button("Choose accessible photos") { showsLimitedPicker = true }
            }
            Button("Change access in Settings") { openSettings() }
            Text("Comparisons use local previews only. Nothing is changed unless you confirm an action.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permission: some View {
        ContentUnavailableView {
            Label("Access your photos", systemImage: "photo.on.rectangle")
        } description: {
            switch library.authorization {
            case .denied:
                Text("Photo access is off. In Settings, allow full access or select a limited set of photos to compare.")
            case .restricted:
                Text("Photo access is restricted on this device. Review device restrictions to enable it.")
            default:
                Text("Choose full access or select specific photos in the system prompt. We use capture times and on-device visual comparisons to help you review nearby shots. Deletions require a separate confirmation and go to Recently Deleted.")
            }
        } actions: {
            if library.authorization == .notDetermined {
                Button("Choose photo access") { Task { await library.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            } else if library.authorization == .denied {
                Button("Open Settings", action: openSettings).buttonStyle(.borderedProminent)
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

/// A cleanup-category row: icon, title, and a trailing status (count, progress,
/// or a short hint).
struct CategoryRow: View {
    enum Detail {
        case count(Int, unit: String)
        case progress(String)
        case text(String)
    }

    let title: String
    let systemImage: String
    let detail: Detail

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            Text(title)
            Spacer()
            trailing
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch detail {
        case let .count(value, unit):
            Text("\(value) \(unit)")
        case let .progress(text):
            HStack(spacing: 6) {
                ProgressView()
                if !text.isEmpty { Text(text) }
            }
        case let .text(text):
            Text(text)
        }
    }
}

#Preview { CleanupHomeView() }
