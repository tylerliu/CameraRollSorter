import SwiftUI

/// A full-screen, swipeable viewer over a list of photo identifiers, reusing
/// `ZoomablePhotoView` for pinch-zoom, pan, and Live Photo playback. Generic so
/// any category list (Live → Still, Blurry, …) can present a large view.
///
/// Presented as a sheet/full-screen cover. Paging is disabled while an image is
/// zoomed so panning doesn't fight the pager.
struct PhotoDetailPager: View {
    let identifiers: [String]
    @Binding var currentID: String?
    /// Optional selection set. When provided, a tick/circle in the toolbar
    /// reflects and toggles whether the current photo is selected (e.g. marked
    /// for conversion). When nil, no selection affordance is shown.
    @Binding var selection: Set<String>?
    @Environment(\.dismiss) private var dismiss
    @State private var isZoomed = false
    @State private var infoID: String?

    init(
        identifiers: [String],
        currentID: Binding<String?>,
        selection: Binding<Set<String>?> = .constant(nil)
    ) {
        self.identifiers = identifiers
        self._currentID = currentID
        self._selection = selection
    }

    var body: some View {
        NavigationStack {
            TabView(selection: selectionBinding) {
                ForEach(identifiers, id: \.self) { id in
                    ZoomablePhotoView(
                        identifier: id,
                        isZoomed: $isZoomed,
                        onSwipeUp: { infoID = id }
                    )
                    .tag(id)
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: identifiers.count > 1 ? .automatic : .never))
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if let position {
                        Text("\(position) of \(identifiers.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selection != nil { selectionToggle }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: infoPresented) {
                if let infoID {
                    PhotoInfoView(identifier: infoID)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    @ViewBuilder
    private var selectionToggle: some View {
        let id = currentID ?? identifiers.first
        let isSelected = id.map { selection?.contains($0) ?? false } ?? false
        Button {
            guard let id else { return }
            if selection?.contains(id) == true {
                selection?.remove(id)
            } else {
                selection?.insert(id)
            }
        } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .accessibilityLabel(isSelected ? "Selected for conversion. Tap to deselect." : "Not selected. Tap to select for conversion.")
    }

    private var infoPresented: Binding<Bool> {
        Binding(get: { infoID != nil }, set: { if !$0 { infoID = nil } })
    }

    /// Bridges the optional `currentID` to the non-optional TabView selection,
    /// falling back to the first identifier.
    private var selectionBinding: Binding<String> {
        Binding(
            get: { currentID ?? identifiers.first ?? "" },
            set: { currentID = $0 }
        )
    }

    private var position: Int? {
        guard let currentID, let index = identifiers.firstIndex(of: currentID) else { return nil }
        return index + 1
    }
}
