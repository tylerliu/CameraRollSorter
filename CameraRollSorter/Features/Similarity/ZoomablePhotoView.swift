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

    // Last successfully loaded image for the current identifier.
    @State private var displayedImage: UIImage? = nil
    // True after 300 ms if the image for `identifier` hasn't loaded yet.
    @State private var showSpinner: Bool = false

    var body: some View {
        ZStack {
            if let img = displayedImage {
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

            if showSpinner || displayedImage == nil {
                ProgressView()
            }
        }
        .task(id: identifier) {
            // Reveal spinner if the image hasn't loaded within 300 ms.
            let graceTimer = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { showSpinner = true }
            }
            let image = await loadImage(identifier: identifier)
            graceTimer.cancel()
            if let image { displayedImage = image }
            showSpinner = false
        }
        .accessibilityLabel("Photo. Tap to toggle selection. Pinch to zoom. Swipe up for information.")
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
