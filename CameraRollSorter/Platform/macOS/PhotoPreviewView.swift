#if os(macOS)
import Photos
import PhotosUI
import SwiftUI

/// macOS large single-photo view — the counterpart of the touch-driven
/// `ZoomablePhotoView` on iOS. Shows the photo aspect-fit, with the Live badge,
/// and plays Live Photo motion through `PHLivePhotoView` (hover its badge or
/// use its playback control). A click calls `onClick` (e.g. toggle keep).
///
/// Deliberately no zoom, swipe, or long-press yet. Zoom (trackpad pinch,
/// ⌘+ / ⌘−) and keyboard handling belong to the Mac screens that host this.
struct PhotoPreviewView: View {
    let identifier: String
    /// Show the Live badge and play Live Photo motion.
    var showsLivePhoto: Bool = true
    var onClick: (() -> Void)? = nil

    @State private var image: PlatformImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var variation: LivePhotoVariation = .none
    @State private var showSpinner = false
    @State private var finished = false

    private var isLivePhoto: Bool { variation.hasPlayableMotion }

    var body: some View {
        ZStack {
            if showsLivePhoto, isLivePhoto, let livePhoto {
                LivePhotoPlayer(livePhoto: livePhoto)
            } else if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            } else if finished {
                Label("Preview unavailable locally", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }

            if showSpinner {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onClick?() }
        .overlay(alignment: .topLeading) {
            if showsLivePhoto { LivePhotoBadge(variation: variation) }
        }
        .task(id: identifier) {
            // Keep the previous photo on screen while the next one loads; show a
            // spinner only if loading takes longer than 300 ms.
            let graceTimer = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { showSpinner = true }
            }
            livePhoto = nil
            finished = false
            variation = PhotoPreviewLoading.variation(for: identifier)
            let loaded = await PhotoPreviewLoading.previewImage(for: identifier)
            guard !Task.isCancelled else { graceTimer.cancel(); return }
            image = loaded
            finished = true
            showSpinner = false
            graceTimer.cancel()
            if showsLivePhoto && isLivePhoto {
                livePhoto = await PhotoPreviewLoading.livePhoto(for: identifier)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLivePhoto ? "Live Photo" : "Photo")
        .accessibilityAddTraits(onClick != nil ? .isButton : [])
    }
}

/// `PHLivePhotoView` host. Aspect-fit is its default content mode.
private struct LivePhotoPlayer: NSViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.livePhoto = livePhoto
        return view
    }

    func updateNSView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
    }

    static func dismantleNSView(_ view: PHLivePhotoView, coordinator: ()) {
        view.stopPlayback()
        view.livePhoto = nil
    }
}
#endif
