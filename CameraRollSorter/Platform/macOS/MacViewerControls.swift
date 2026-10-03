#if os(macOS)
import AppKit
import SwiftUI

/// An inline inspector with enough width and height for readable metadata.
struct MacPhotoInfoPane: View {
    let identifier: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Info").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide photo info")
                    .accessibilityLabel("Hide photo info")
            }
            .padding(16)
            Divider()
            PhotoInfoView(identifier: identifier)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(.background)
    }
}

/// Shared toolbar zoom control for both Mac viewers.
struct MacPhotoZoomControl: View {
    @Binding var scale: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass")
            Slider(value: $scale, in: 1...5)
                .frame(width: 120)
                .accessibilityLabel("Photo zoom")
            Image(systemName: "plus.magnifyingglass")
        }
        .foregroundStyle(.secondary)
    }
}

/// Keeps adjacent photos loaded while a two-finger swipe follows the trackpad.
struct MacPhotoPager: View {
    let identifiers: [String]
    @Binding var currentIndex: Int
    @Binding var zoomScale: CGFloat
    var onClick: ((String) -> Void)? = nil
    var animatesIndexChanges = true
    @State private var translation: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            ZStack {
                ForEach(identifiers.indices.filter { abs($0 - currentIndex) <= 1 }, id: \.self) { index in
                    PhotoPreviewView(identifier: identifiers[index], onClick: {
                        onClick?(identifiers[index])
                    }, isCurrent: index == currentIndex,
                       zoomScale: index == currentIndex ? $zoomScale : .constant(1))
                    .frame(width: width, height: geometry.size.height)
                    .offset(x: CGFloat(index - currentIndex) * width + translation)
                }
            }
            .frame(width: width, height: geometry.size.height)
            .clipped()
            .overlay {
                MacPhotoPagingSurface(allowsPaging: zoomScale <= 1, onMove: { step in
                    let target = currentIndex + step
                    guard identifiers.indices.contains(target) else { return }
                    translation = 0
                    currentIndex = target
                }, onZoom: { factor in
                    zoomScale = min(5, max(1, zoomScale * factor))
                }) { delta in
                    let atEdge = (currentIndex == 0 && delta > 0)
                        || (currentIndex == identifiers.count - 1 && delta < 0)
                    translation = atEdge ? delta * 0.25 : delta
                } onEnd: { cancelled in
                    let step = translation < 0 ? 1 : -1
                    let target = currentIndex + step
                    withAnimation(.easeOut(duration: 0.25)) {
                        if !cancelled, abs(translation) > min(120, width * 0.2),
                           identifiers.indices.contains(target) {
                            currentIndex = target
                        }
                        translation = 0
                    }
                }
            }
        }
        // Comparison viewers choose animation at the interaction site. A
        // constant trigger preserves those explicit animations while default
        // viewers animate every page change, including keyboard navigation.
        .animation(.easeOut(duration: 0.25), value: animatesIndexChanges ? currentIndex : -1)
        .onChange(of: currentIndex) { _, _ in zoomScale = 1 }
    }
}

/// Observes precise horizontal scroll gestures over the photo, excluding momentum.
private struct MacPhotoPagingSurface: NSViewRepresentable {
    let allowsPaging: Bool
    let onMove: (Int) -> Void
    let onZoom: (CGFloat) -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (Bool) -> Void

    func makeNSView(context: Context) -> PagingView { PagingView() }
    func updateNSView(_ view: PagingView, context: Context) {
        view.allowsPaging = allowsPaging
        view.onMove = onMove
        view.onZoom = onZoom
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class PagingView: NSView {
        var allowsPaging = true
        var onMove: ((Int) -> Void)?
        var onZoom: ((CGFloat) -> Void)?
        var onChange: ((CGFloat) -> Void)?
        var onEnd: ((Bool) -> Void)?
        private var horizontal: CGFloat = 0
        private var vertical: CGFloat = 0
        private var tracking = false
        private var isHorizontal = false
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                // Handle viewer shortcuts only while its photo surface is
                // visible in the active window, without intercepting text editing.
                if event.type == .keyDown {
                    guard self.window?.isKeyWindow == true,
                          !self.isHiddenOrHasHiddenAncestor, !self.visibleRect.isEmpty,
                          !(self.window?.firstResponder is NSTextView) else { return event }
                    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                    if modifiers == .command || modifiers == [.command, .shift] {
                        switch event.charactersIgnoringModifiers {
                        case "+", "=": self.onZoom?(1.25); return nil
                        case "-", "_": self.onZoom?(1 / 1.25); return nil
                        default: return event
                        }
                    }
                    guard modifiers.isEmpty else { return event }
                    if event.keyCode == 123 { self.onMove?(-1); return nil }
                    if event.keyCode == 124 { self.onMove?(1); return nil }
                    return event
                }
                guard self.allowsPaging else { self.tracking = false; return event }
                guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return event }
                if event.phase.contains(.began) {
                    self.tracking = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                    self.horizontal = 0
                    self.vertical = 0
                    self.isHorizontal = false
                }
                guard self.tracking else { return event }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    self.tracking = false
                    self.onEnd?(event.phase.contains(.cancelled))
                    return self.isHorizontal ? nil : event
                }
                self.horizontal += event.scrollingDeltaX
                self.vertical += event.scrollingDeltaY
                if abs(self.horizontal) > 8 && abs(self.horizontal) > abs(self.vertical) * 1.5 {
                    self.isHorizontal = true
                }
                if self.isHorizontal {
                    self.onChange?(self.horizontal)
                    return nil
                }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#endif
