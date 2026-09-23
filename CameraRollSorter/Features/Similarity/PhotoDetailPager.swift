import Photos
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
    /// When true, a fixed strip of the current photo's nearest temporal
    /// neighbors (2 before + 2 after, by capture time, from the whole library)
    /// is shown beneath the image. Used by the Low-aesthetic flow so the user
    /// can spot a better nearby shot; off for other categories.
    let showsNeighbors: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isZoomed = false
    @State private var infoID: String?
    /// The neighbor (or reviewed photo) currently being held for a peek preview.
    @State private var peekID: String?

    init(
        identifiers: [String],
        currentID: Binding<String?>,
        selection: Binding<Set<String>?> = .constant(nil),
        showsNeighbors: Bool = false
    ) {
        self.identifiers = identifiers
        self._currentID = currentID
        self._selection = selection
        self.showsNeighbors = showsNeighbors
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
            .safeAreaInset(edge: .bottom) {
                // Nearest-in-time neighbors for the current photo. Hidden while
                // zoomed so it doesn't fight the pinch/pan surface.
                if showsNeighbors, !isZoomed, let id = currentID ?? identifiers.first {
                    NeighborStrip(identifier: id, onPeek: { peekID = $0 })
                        .background(.ultraThinMaterial)
                }
            }
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
        // Press-and-hold peek: a large, screen-centered preview that blurs the
        // whole screen behind it. Lives at the top level so it covers the
        // toolbar and neighbor strip, not just the image area.
        .overlay {
            if let peekID {
                PeekOverlay(identifier: peekID)
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

/// Full-screen, screen-centered preview shown while a neighbor thumbnail is held
/// down. It blurs the entire screen behind it (`.ultraThinMaterial` over an
/// `ignoresSafeArea` fill) with the previewed photo centered on top, sized to
/// 0.9 × screen width with rounded corners. Height follows the photo's own
/// aspect ratio, so portrait and landscape shots both read at full width.
/// Non-interactive; it exists only to be looked at and vanishes on release.
private struct PeekOverlay: View {
    let identifier: String

    @State private var image: UIImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        GeometryReader { geo in
            let targetWidth = geo.size.width * 0.9
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)      // blurs whatever is underneath
                    .ignoresSafeArea()
                Color.black.opacity(0.25).ignoresSafeArea()

                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            // Fix the width; height follows the photo's aspect
                            // ratio. Cap height so a very tall portrait can't
                            // overflow the screen.
                            .frame(width: targetWidth)
                            .frame(maxHeight: geo.size.height * 0.9)
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(radius: 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // center in screen
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
        .task(id: identifier) { load() }
    }

    private func load() {
        image = nil
        // A generously-sized aspect-fit request returns the photo at its real
        // aspect ratio (no crop); we then lay it out to 0.9 × screen width.
        request = ThumbnailProvider.shared.requestThumbnail(
            id: identifier, size: 600, fill: false
        ) { result, isFinal in
            if let result { image = result }
            if isFinal { request = nil }
        }
    }
}
