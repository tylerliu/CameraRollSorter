import Photos
import SwiftUI

struct SequenceLibraryView: View {
    @State private var library = PhotoLibraryModel()
    @State private var showsSettings = false
    @State private var showsLimitedPicker = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if library.canRead { sequences }
                else { permission }
            }
            .navigationTitle("Camera Roll Sorter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Review settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                }
            }
            .sheet(isPresented: $showsSettings, onDismiss: library.applyThreshold) { ReviewSettingsView() }
            .background {
                LimitedLibraryPicker(isPresented: $showsLimitedPicker, onFinished: library.refresh)
                    .frame(width: 0, height: 0)
            }
        }
        .task { library.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await library.syncLibrary() } }
        }
    }

    private var sequences: some View {
        List {
            Section {
                Label(library.authorization == .limited ? "Limited photo access" : "Full photo access", systemImage: "photo.on.rectangle")
                if library.authorization == .limited {
                    Text("Results include only the photos you have allowed.")
                    Button("Choose accessible photos") { showsLimitedPicker = true }
                }
                Button("Change access in Settings") { openSettings() }
                Text("Comparisons use local previews only. Nothing is changed unless you confirm a deletion in the chooser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Similarity distance ≤ \(library.threshold, format: .number.precision(.fractionLength(2))) · change in review settings")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = library.analysisError { Text(error).foregroundStyle(.secondary) }
            }
            Section("Similar photos") {
                if library.isScanning {
                    ProgressView(library.progress)
                }
                if library.hasScanned || !library.groups.isEmpty {
                    if !library.summary.isEmpty {
                        Text(library.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    if library.hasScanned && library.groups.isEmpty {
                        ContentUnavailableView("No groups found", systemImage: "photo.stack", description: Text(library.analysisError == nil ? "No measured matches met the distance threshold. Try adjusting it in settings. Photos unavailable locally cannot be matched." : "Similarity analysis did not finish. Pull to refresh to retry."))
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
        .refreshable { library.refresh() }
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

#Preview { SequenceLibraryView() }
