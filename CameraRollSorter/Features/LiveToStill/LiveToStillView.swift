import Photos
import PhotosUI
import SwiftUI

/// Detail screen for the "Live → Still" category. Lists convertible Live Photos
/// (genuine Live and Long Exposure only — no Loop/Bounce) and converts the
/// selected ones to plain stills, preserving metadata. Owns its own model so
/// scanning runs independently of similarity analysis.
struct LiveToStillView: View {
    @State var model: LiveToStillModel

    @State private var selection: Set<String> = []
    @State private var isConverting = false
    @State private var showsConfirm = false
    @State private var conversionError: String?
    @State private var detailID: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 3)]

    var body: some View {
        Group {
            if model.isScanning && model.items.isEmpty {
                ProgressView("Finding Live Photos…")
            } else if model.hasScanned && model.items.isEmpty {
                ContentUnavailableView(
                    "No Live Photos",
                    systemImage: "livephoto",
                    description: Text("No convertible Live Photos were found. Loop and Bounce effects aren’t included, and photos unavailable locally can’t be converted.")
                )
            } else {
                grid
            }
        }
        .navigationTitle("Live → Still")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selection.isEmpty {
                    Button("Select All") { selection = Set(model.items.map(\.id)) }
                        .disabled(model.items.isEmpty)
                } else {
                    Button("Clear") { selection.removeAll() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
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
        .fullScreenCover(isPresented: detailPresented) {
            PhotoDetailPager(
                identifiers: model.items.map(\.id),
                currentID: $detailID,
                selection: optionalSelectionBinding
            )
        }
        .task { if !model.hasScanned { model.scan() } }
    }

    private var detailPresented: Binding<Bool> {
        Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } })
    }

    /// Bridges the non-optional `selection` to the pager's optional binding so
    /// the pager shows a selection tick.
    private var optionalSelectionBinding: Binding<Set<String>?> {
        Binding(get: { selection }, set: { if let new = $0 { selection = new } })
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(model.items) { item in
                    cell(for: item)
                }
            }
            .padding(3)
        }
    }

    private func cell(for item: LivePhotoItem) -> some View {
        let selected = selection.contains(item.id)
        return PhotoThumbnail(identifier: item.id, size: 120, fill: true, cornerRadius: 4)
            .overlay(alignment: .topLeading) {
                Image(systemName: "livephoto")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.35), in: Circle())
                    .padding(4)
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 4).stroke(.tint, lineWidth: 3)
                }
            }
            // Tap the photo body to open the large zoomable viewer.
            .contentShape(Rectangle())
            .onTapGesture { detailID = item.id }
            // The tick is a separate tap target that toggles selection.
            .overlay(alignment: .bottomTrailing) {
                Button {
                    toggle(item.id)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.4))
                        .font(.title3)
                        .padding(5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selected ? "Selected. Tap to deselect." : "Not selected. Tap to select.")
            }
            .accessibilityLabel("Live Photo from \(item.date.formatted(date: .abbreviated, time: .shortened))")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.items.count) Live Photos")
                        .font(.subheadline.weight(.semibold))
                    Text(selection.isEmpty ? "Tap the tick to select · Select All above" : "\(selection.count) selected")
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

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
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
                conversionError = error.localizedDescription
            }
            isConverting = false
        }
    }
}
