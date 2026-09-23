import Photos
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Public SwiftUI wrapper

struct ZoomablePhotoView: View {
    let identifier: String
    /// Called when the user single-taps the image (toggle keep/delete).
    let onTap: () -> Void
    /// Called when the user swipes up while not zoomed (open info sheet).
    let onSwipeUp: () -> Void
    /// Driven to true while scale > 1 so the caller can raise zIndex.
    @Binding var isZoomed: Bool

    init(
        identifier: String,
        isZoomed: Binding<Bool> = .constant(false),
        onTap: @escaping () -> Void = {},
        onSwipeUp: @escaping () -> Void
    ) {
        self.identifier = identifier
        self._isZoomed = isZoomed
        self.onTap = onTap
        self.onSwipeUp = onSwipeUp
    }

    /// When true, overlay a Live Photo player so long-press plays the motion.
    /// Auto-detected from the asset, but exposed so callers can force it off.
    var showsLivePhoto: Bool = true

    // Last successfully loaded image for the current identifier.
    @State private var displayedImage: UIImage? = nil
    // True after 300 ms if the image for `identifier` hasn't loaded yet.
    @State private var showSpinner: Bool = false
    // The Live Photo flavor of this asset (drives the badge + playback).
    @State private var variation: LivePhotoVariation = .none

    // Loaded Live Photo (when this asset is Live and playback is enabled).
    @State private var livePhoto: PHLivePhoto?

    /// Whether to offer press-and-hold playback: any Live-flagged asset.
    private var isLivePhoto: Bool { variation != .none }

    var body: some View {
        ZStack {
            // Live path: a single UIScrollView hosting PHLivePhotoView, so
            // pinch-zoom, pan, swipe-up, and press-and-hold playback all share
            // one coordinated gesture surface. Falls back to the still image
            // until the Live Photo finishes loading.
            if showsLivePhoto, isLivePhoto, let livePhoto {
                LivePhotoZoomView(
                    livePhoto: livePhoto,
                    onZoomStarted: { isZoomed = true },
                    onZoomEnded: { scale in isZoomed = scale > 1.01 },
                    onSingleTap: onTap,
                    onSwipeUp: onSwipeUp
                )
                .opacity(showSpinner ? 0.5 : 1)
            } else if let img = displayedImage {
                // Still path (also the pre-load placeholder for Live Photos).
                ZoomableImage(
                    image: img,
                    onZoomStarted: { isZoomed = true },
                    onZoomEnded: { scale in isZoomed = scale > 1.01 },
                    onSingleTap: onTap,
                    onSwipeUp: onSwipeUp
                )
                .id(ObjectIdentifier(img))
                .opacity(showSpinner ? 0.5 : 1)
                .allowsHitTesting(!showSpinner)
            }

            if showSpinner || (displayedImage == nil && livePhoto == nil) {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if showsLivePhoto, let badge = variation.badgeText {
                HStack(spacing: 4) {
                    variation.badgeIcon
                    Text(badge)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(10)
                .allowsHitTesting(false)
            }
        }
        .task(id: identifier) {
            // Reveal spinner if nothing has loaded within 300 ms.
            let graceTimer = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { showSpinner = true }
            }
            livePhoto = nil
            variation = Self.detectVariation(identifier)
            // Load a still first for an immediate frame; then, if Live, load the
            // Live Photo and swap the scroll-view host in.
            let image = await loadImage(identifier: identifier)
            if let image { displayedImage = image }
            showSpinner = false
            graceTimer.cancel()
            if showsLivePhoto && isLivePhoto {
                livePhoto = await loadLivePhoto(identifier: identifier)
            }
        }
        .accessibilityLabel(isLivePhoto
            ? "Live Photo. Press and hold to play. Pinch to zoom. Swipe up for information."
            : "Photo. Pinch to zoom. Swipe up for information.")
    }

    private static func detectVariation(_ identifier: String) -> LivePhotoVariation {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return .none
        }
        return LivePhotoVariation.of(asset)
    }

    /// Loads the Live Photo for press-and-hold playback. Returns nil if
    /// unavailable locally.
    private func loadLivePhoto(identifier: String) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier], options: nil
            ).firstObject else {
                continuation.resume(returning: nil)
                return
            }
            var resumed = false
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                guard !resumed else { return }
                if cancelled {
                    resumed = true
                    continuation.resume(returning: nil)
                } else if !degraded {
                    resumed = true
                    continuation.resume(returning: livePhoto)
                }
                // Ignore degraded deliveries; wait for the final one.
            }
        }
    }

    /// Loads a 1024-pt preview for the given asset identifier. Waits for the
    /// final (non-degraded) delivery. Returns nil if unavailable.
    private func loadImage(identifier: String) async -> UIImage? {
        await withCheckedContinuation { continuation in
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier], options: nil
            ).firstObject else {
                continuation.resume(returning: nil)
                return
            }
            var resumed = false
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1024, height: 1024),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                guard !resumed else { return }
                if cancelled {
                    resumed = true
                    continuation.resume(returning: nil)
                } else if !degraded {
                    resumed = true
                    continuation.resume(returning: image)
                }
                // Ignore degraded previews; wait for the final delivery.
            }
        }
    }
}

// MARK: - UIScrollView-backed zoomable content (shared)

/// A generic `UIViewRepresentable` that makes any `UIView` zoomable by hosting
/// it inside a `UIScrollView`. Pinch-zoom and simultaneous panning are handled
/// natively by UIScrollView — pure SwiftUI gestures cannot do this reliably.
///
/// Key detail: the content view is pinned to the scroll view's dimensions with
/// Auto Layout and uses `.scaleAspectFit`. We do NOT manually set frames,
/// contentSize, or re-centre during zoom — doing so fights UIScrollView's own
/// zoom transform and breaks panning.
///
/// Both the still image (`UIImageView`) and Live Photo (`PHLivePhotoView`)
/// hosts are built from this one type, differing only in `makeContent` and the
/// optional `updateContent` / `teardownContent` hooks.
private struct ZoomableScrollView<Content: UIView>: UIViewRepresentable {
    /// Builds the content view to host. Called once in `makeUIView`.
    let makeContent: () -> Content
    /// Optional per-update reconfiguration (e.g. swap a PHLivePhoto).
    var updateContent: ((Content) -> Void)?
    /// Optional teardown (e.g. stop Live Photo playback) on dismantle.
    var teardownContent: ((Content) -> Void)?
    var onZoomStarted: (() -> Void)?
    var onZoomEnded: ((CGFloat) -> Void)?
    var onSingleTap: (() -> Void)?
    var onSwipeUp: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5.0
        scrollView.minimumZoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        // Let the zoomed content overflow the frame rather than being clipped.
        scrollView.clipsToBounds = false

        let content = makeContent()
        content.contentMode = .scaleAspectFit
        content.tag = 1
        content.backgroundColor = .clear
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        context.coordinator.content = content
        context.coordinator.teardown = teardownContent

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            content.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            content.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        // Single-tap toggles selection/keep. A hosted view's own recognizers
        // (e.g. PHLivePhotoView's press-and-hold playback) are separate and
        // are not blocked by this.
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(recognizer:))
        )
        singleTap.numberOfTapsRequired = 1
        scrollView.addGestureRecognizer(singleTap)

        // Swipe-up: info sheet (only fires when not zoomed).
        let swipeUp = UISwipeGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSwipeUp(recognizer:))
        )
        swipeUp.direction = .up
        scrollView.addGestureRecognizer(swipeUp)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onZoomStarted = onZoomStarted
        context.coordinator.onZoomEnded = onZoomEnded
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onSwipeUp = onSwipeUp
        if let content = context.coordinator.content { updateContent?(content) }
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        if let content = coordinator.content { coordinator.teardown?(content) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var content: Content?
        var teardown: ((Content) -> Void)?
        var onZoomStarted: (() -> Void)?
        var onZoomEnded: ((CGFloat) -> Void)?
        var onSingleTap: (() -> Void)?
        var onSwipeUp: (() -> Void)?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(1)
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            onZoomStarted?()
        }

        func scrollViewDidEndZooming(
            _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
        ) {
            // Snap back to 1× when the pinch is released, so content returns to
            // its original size and frame (comparison workflow).
            if scale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            }
            onZoomEnded?(scrollView.minimumZoomScale)
        }

        @objc func handleSingleTap(recognizer: UITapGestureRecognizer) {
            onSingleTap?()
        }

        @objc func handleSwipeUp(recognizer: UISwipeGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView,
                  scrollView.zoomScale <= scrollView.minimumZoomScale else { return }
            onSwipeUp?()
        }
    }
}

// MARK: - Still image / Live Photo builders

/// Zoomable still image, hosting a `UIImageView`.
private struct ZoomableImage: View {
    let image: UIImage
    var onZoomStarted: (() -> Void)?
    var onZoomEnded: ((CGFloat) -> Void)?
    var onSingleTap: (() -> Void)?
    var onSwipeUp: (() -> Void)?

    var body: some View {
        ZoomableScrollView<UIImageView>(
            makeContent: { UIImageView(image: image) },
            onZoomStarted: onZoomStarted,
            onZoomEnded: onZoomEnded,
            onSingleTap: onSingleTap,
            onSwipeUp: onSwipeUp
        )
    }
}

/// Zoomable Live Photo, hosting a `PHLivePhotoView`. The hosted view's built-in
/// press-and-hold playback coexists with the scroll view's zoom/pan and the
/// swipe-up info gesture on one coordinated gesture surface.
private struct LivePhotoZoomView: View {
    let livePhoto: PHLivePhoto
    var onZoomStarted: (() -> Void)?
    var onZoomEnded: ((CGFloat) -> Void)?
    var onSingleTap: (() -> Void)?
    var onSwipeUp: (() -> Void)?

    var body: some View {
        ZoomableScrollView<PHLivePhotoView>(
            makeContent: {
                let view = PHLivePhotoView()
                view.livePhoto = livePhoto
                return view
            },
            updateContent: { (view: PHLivePhotoView) in
                if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
            },
            teardownContent: { (view: PHLivePhotoView) in
                view.stopPlayback()
                view.livePhoto = nil
            },
            onZoomStarted: onZoomStarted,
            onZoomEnded: onZoomEnded,
            onSingleTap: onSingleTap,
            onSwipeUp: onSwipeUp
        )
    }
}

extension LivePhotoVariation {
    /// The badge's leading glyph, specific to each effect. Long Exposure uses
    /// the timer hand inside a dotted ring (matching the Photos long-exposure
    /// icon), which is composed from two symbols rather than a single one.
    @ViewBuilder
    var badgeIcon: some View {
        switch self {
        case .none, .live:
            Image(systemName: "livephoto")
        case .loop:
            Image(systemName: "arrow.triangle.2.circlepath")   // continuous loop
        case .bounce:
            Image(systemName: "arrow.left.arrow.right")        // back-and-forth
        case .longExposure:
            // Timer hand centered in a dotted ring, like the Photos icon.
            ZStack {
                Image(systemName: "circle.dotted")
                Image(systemName: "timer")
                    .font(.system(size: 7, weight: .semibold))
            }
        }
    }
}
