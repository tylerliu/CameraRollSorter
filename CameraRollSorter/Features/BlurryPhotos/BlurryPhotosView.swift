import Photos
import SwiftUI

/// Detail screen for the "Low-aesthetic" category. Lists non-utility photos
/// that Vision's image-aesthetics request scored below the active sensitivity
/// cutoff, and lets the user delete the ones they no longer want. Owns its own
/// model so scanning runs independently of the other cleanup flows.
///
/// The grid, selection, drag-select, detail pager, scan-controls header, and
/// scroll restoration all live in the shared `PhotoSelectionGrid` (the same
/// component the Live → Still flow uses). This view owns the model, the
/// selection, and the bottom action bar.
///
/// Deletion deliberately has **no** in-app confirmation dialog — the OS
/// Recently Deleted prompt is the only gate. Tapping Delete calls
/// `model.deletePhotos(selection)` directly; failures surface through the
/// error `.alert`.
struct BlurryPhotosView: View {
    @State var model: BlurryPhotosModel

    @State private var selection: Set<String> = []
    @State private var isDeleting = false
    @State private var deletionError: String?

    var body: some View {
        PhotoSelectionGrid(
            ids: model.items.map(\.id),
            selection: $selection,
            scrollAnchorID: $model.scrollAnchorID,
            isScanning: model.isScanning,
            hasScanned: model.hasScanned,
            hasMoreToScan: model.hasMoreToScan,
            scanMore: { model.scanMore(currentIndex: $0) },
            applyScanSettings: { model.applyScanSettings() },
            scanDirectionRaw: $model.scanDirectionRaw,
            scanStartEnabled: $model.scanStartEnabled,
            scanStartInterval: $model.scanStartInterval,
            libraryDateRange: model.libraryDateRange,
            navigationTitle: "Low-aesthetic",
            scanningText: "Finding low-aesthetic photos…",
            emptyState: AnyView(
                ContentUnavailableView(
                    "No low-aesthetic photos",
                    systemImage: "wand.and.stars",
                    description: Text("No low-aesthetic photos were found in this range. Try a higher sensitivity in Settings, or widen the scan window. Aesthetics scoring needs a physical device, and photos unavailable locally can’t be checked.")
                )
            ),
            showsNeighbors: true,
            actionBar: { isSelecting in actionBar(isSelecting: isSelecting) }
        )
        .alert("Couldn’t delete", isPresented: deletionAlertBinding) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "Try again after checking photo access.")
        }
        .task { if !model.hasScanned { model.scan() } }
        .onAppear { model.setListActive(true) }
        .onDisappear { model.setListActive(false) }
    }

    // MARK: - Action bar

    private func actionBar(isSelecting: Bool) -> some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.items.count) low-aesthetic \(model.items.count == 1 ? "photo" : "photos")")
                        .font(.subheadline.weight(.semibold))
                    Text(selectionHint(isSelecting: isSelecting))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    delete()
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Label("Delete \(selection.count)", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || isDeleting)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .background(.bar)
    }

    private func selectionHint(isSelecting: Bool) -> String {
        if !selection.isEmpty { return "\(selection.count) selected" }
        return isSelecting ? "Tap or drag to select" : "Tap Select to choose photos"
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })
    }

    private func delete() {
        let ids = selection
        guard !ids.isEmpty else { return }
        isDeleting = true
        Task { @MainActor in
            do {
                _ = try await model.deletePhotos(ids)
                selection.removeAll()
            } catch {
                deletionError = error.localizedDescription
            }
            isDeleting = false
        }
    }
}
