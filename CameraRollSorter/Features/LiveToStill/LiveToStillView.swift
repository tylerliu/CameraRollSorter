import Photos
import PhotosUI
import SwiftUI

/// Detail screen for the "Live → Still" category. Lists convertible Live Photos
/// (genuine Live and Long Exposure only — no Loop/Bounce) and converts the
/// selected ones to plain stills, preserving metadata. Owns its own model so
/// scanning runs independently of similarity analysis.
///
/// The grid, selection, drag-select, detail pager, scan-controls header, and
/// scroll restoration all live in the shared `PhotoSelectionGrid`; this view
/// only owns the model, the selection, and the Convert action bar (with its
/// in-app confirmation dialog — the one behavior unique to this flow).
struct LiveToStillView: View {
    @State var model: LiveToStillModel

    @State private var selection: Set<String> = []
    @State private var isConverting = false
    @State private var showsConfirm = false
    @State private var conversionError: String?

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
            navigationTitle: "Live → Still",
            scanningText: "Finding Live Photos…",
            emptyState: AnyView(
                ContentUnavailableView(
                    "No Live Photos",
                    systemImage: "livephoto",
                    description: Text("No convertible Live Photos were found in this range. Loop and Bounce effects aren’t included, and photos unavailable locally can’t be converted.")
                )
            ),
            actionBar: { isSelecting in actionBar(isSelecting: isSelecting) }
        )
        .alert("Couldn’t convert", isPresented: conversionAlertBinding) {
            Button("OK", role: .cancel) { conversionError = nil }
        } message: {
            Text(conversionError ?? "Try again after checking photo access.")
        }
        .confirmationDialog(
            "Convert \(selection.count) to still?",
            isPresented: $showsConfirm,
            titleVisibility: .visible
        ) {
            Button("Convert \(selection.count)", role: .destructive) { convert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The still keeps the photo and its metadata. The Live Photo’s motion is removed and the original moves to Recently Deleted.")
        }
        .task { if !model.hasScanned { model.scan() } }
        .onAppear { model.setListActive(true) }
        .onDisappear { model.setListActive(false) }
    }

    private func actionBar(isSelecting: Bool) -> some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.items.count) Live Photos")
                        .font(.subheadline.weight(.semibold))
                    Text(selectionHint(isSelecting: isSelecting))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showsConfirm = true
                } label: {
                    if isConverting {
                        ProgressView()
                    } else {
                        Label("Convert \(selection.count)", systemImage: "photo")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || isConverting)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .background(.bar)
    }

    private func selectionHint(isSelecting: Bool) -> String {
        if !selection.isEmpty { return String(localized: "\(selection.count) selected") }
        return isSelecting
            ? String(localized: "Tap or drag to select")
            : String(localized: "Tap Select to choose photos")
    }

    private var conversionAlertBinding: Binding<Bool> {
        Binding(get: { conversionError != nil }, set: { if !$0 { conversionError = nil } })
    }

    private func convert() {
        let ids = selection
        guard !ids.isEmpty else { return }
        isConverting = true
        Task { @MainActor in
            do {
                _ = try await model.convertToStill(ids)
                selection.removeAll()
            } catch {
                // Tapping Cancel on the system delete prompt isn't an error.
                if !PhotoLibraryErrors.isUserCancelled(error) {
                    conversionError = error.localizedDescription
                }
            }
            isConverting = false
        }
    }
}
