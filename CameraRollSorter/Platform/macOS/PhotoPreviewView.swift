#if os(macOS)
import AppKit
import Photos
import PhotosUI
import SwiftUI

/// Shared Mac preview with persistent zoom and independently bounded pan axes.
struct PhotoPreviewView: View {
    let identifier: String
    /// Show the Live badge and play Live Photo motion.
    var showsLivePhoto: Bool = true
    var onClick: (() -> Void)? = nil
    var isCurrent = true
    @Binding var zoomScale: CGFloat

    @State private var magnifyOrigin: CGFloat?
    @State private var pan = CGSize.zero
    @State private var dragOrigin: CGSize?

    @State private var image: PlatformImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var variation: LivePhotoVariation = .none
    @State private var showSpinner = false
    @State private var finished = false

    private var isLivePhoto: Bool { variation.hasPlayableMotion }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let viewport = geometry.size
                let photoSize = image?.size ?? livePhoto?.size ?? viewport
                let fit = min(viewport.width / max(1, photoSize.width), viewport.height / max(1, photoSize.height))
                let fittedSize = CGSize(width: photoSize.width * fit, height: photoSize.height * fit)
                ZStack {
                    Group {
                        if showsLivePhoto, isLivePhoto, let livePhoto {
                            LivePhotoPlayer(livePhoto: livePhoto)
                        } else if let image {
                            Image(platformImage: image).resizable().scaledToFit()
                        } else if finished {
                            Label("Preview unavailable locally", systemImage: "icloud.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: fittedSize.width * zoomScale, height: fittedSize.height * zoomScale)
                    .offset(pan)
                    if showSpinner { ProgressView() }
                }
                .frame(width: viewport.width, height: viewport.height)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { onClick?() }
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard zoomScale > 1 else { return }
                        if dragOrigin == nil { dragOrigin = pan }
                        let origin = dragOrigin ?? .zero
                        pan = boundedPan(CGSize(width: origin.width + value.translation.width,
                                                height: origin.height + value.translation.height),
                                         fittedSize: fittedSize, viewport: viewport)
                    }
                    .onEnded { _ in dragOrigin = nil })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        if magnifyOrigin == nil { magnifyOrigin = zoomScale }
                        zoomScale = min(5, max(1, (magnifyOrigin ?? 1) * value.magnification))
                        pan = boundedPan(pan, fittedSize: fittedSize, viewport: viewport)
                    }
                    .onEnded { _ in magnifyOrigin = nil })
                .overlay {
                    MacPhotoZoomEvents(zoomed: zoomScale > 1) { delta in
                        pan = boundedPan(CGSize(width: pan.width + delta.width,
                                                height: pan.height + delta.height),
                                         fittedSize: fittedSize, viewport: viewport)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showsLivePhoto { LivePhotoBadge(variation: variation) }
                }
                .onChange(of: zoomScale) { _, _ in
                    pan = boundedPan(pan, fittedSize: fittedSize, viewport: viewport)
                }
                .onChange(of: viewport) { _, _ in
                    pan = boundedPan(pan, fittedSize: fittedSize, viewport: viewport)
                }
                .onChange(of: fittedSize) { _, _ in
                    pan = boundedPan(pan, fittedSize: fittedSize, viewport: viewport)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: identifier) { _, _ in resetPan() }
        .onChange(of: isCurrent) { _, _ in resetPan() }
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
        .accessibilityLabel(isLivePhoto ? "Live Photo" : "Photo")
        .accessibilityAddTraits(onClick != nil ? .isButton : [])
    }

    private func resetPan() {
        magnifyOrigin = nil
        pan = .zero
        dragOrigin = nil
    }

    private func boundedPan(_ proposed: CGSize, fittedSize: CGSize, viewport: CGSize) -> CGSize {
        let horizontal = max(0, (fittedSize.width * zoomScale - viewport.width) / 2)
        let vertical = max(0, (fittedSize.height * zoomScale - viewport.height) / 2)
        return CGSize(width: min(horizontal, max(-horizontal, proposed.width)),
                      height: min(vertical, max(-vertical, proposed.height)))
    }
}

/// Observe native trackpad events without blocking Live Photo playback controls.
private struct MacPhotoZoomEvents: NSViewRepresentable {
    let zoomed: Bool
    let onPan: (CGSize) -> Void

    func makeNSView(context: Context) -> EventView { EventView() }
    func updateNSView(_ view: EventView, context: Context) {
        view.zoomed = zoomed
        view.onPan = onPan
    }
    static func dismantleNSView(_ view: EventView, coordinator: ()) { view.removeMonitor() }

    final class EventView: NSView {
        var zoomed = false
        var onPan: ((CGSize) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                guard self.zoomed else { return event }
                self.onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                return nil
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
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
