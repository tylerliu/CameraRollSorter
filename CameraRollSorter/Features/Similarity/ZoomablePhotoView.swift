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
                Label(badge, systemImage: "livephoto")
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

// MARK: - UIScrollView-backed zoomable image (based on Silenterc/ImageViewer)

/// A UIImage wrapper made zoomable by wrapping UIScrollView. Pinch-zoom and
/// simultaneous panning are handled natively by UIScrollView — pure SwiftUI
/// gestures cannot do this reliably.
///
/// Key detail: the UIImageView is pinned to the scroll view's dimensions with
/// Auto Layout and uses `.scaleAspectFit`. We do NOT manually set frames,
/// contentSize, or re-centre during zoom — doing so fights UIScrollView's own
/// zoom transform and breaks panning.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
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
        // Let the zoomed image overflow the frame rather than being clipped.
        scrollView.clipsToBounds = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 1
        imageView.backgroundColor = .clear
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        // Single-tap: toggle keep/delete.
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
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
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
            // Snap back to 1× when the pinch is released, so the image returns
            // to its original size and frame (comparison workflow).
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

// MARK: - UIScrollView-backed zoomable Live Photo

/// A PHLivePhoto wrapper made zoomable by hosting a `PHLivePhotoView` inside a
/// `UIScrollView`. Because the Live Photo view is the scroll view's zooming
/// subview, pinch-zoom, pan, the swipe-up info gesture, AND the built-in
/// press-and-hold playback all coexist on one coordinated gesture surface.
///
/// Mirrors `ZoomableImage`: `.scaleAspectFit`, Auto Layout pinned to the scroll
/// view, and snap-back to 1× when a pinch is released.
private struct LivePhotoZoomView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
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
        scrollView.clipsToBounds = false

        let livePhotoView = PHLivePhotoView()
        livePhotoView.contentMode = .scaleAspectFit
        livePhotoView.livePhoto = livePhoto
        livePhotoView.tag = 1
        livePhotoView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(livePhotoView)

        NSLayoutConstraint.activate([
            livePhotoView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            livePhotoView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            livePhotoView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            livePhotoView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
        context.coordinator.livePhotoView = livePhotoView

        // Single-tap toggles selection/keep. The Live view's own long-press
        // (playback) recognizer is separate and is not blocked by this.
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(recognizer:))
        )
        singleTap.numberOfTapsRequired = 1
        scrollView.addGestureRecognizer(singleTap)

        // Swipe-up: info sheet (only when not zoomed).
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
        if context.coordinator.livePhotoView?.livePhoto !== livePhoto {
            context.coordinator.livePhotoView?.livePhoto = livePhoto
        }
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.livePhotoView?.stopPlayback()
        coordinator.livePhotoView?.livePhoto = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var livePhotoView: PHLivePhotoView?
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
