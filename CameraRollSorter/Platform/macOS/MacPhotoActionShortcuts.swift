#if os(macOS)
import AppKit
import SwiftUI

/// Routes destructive shortcuts only to the visible photo screen, never text editing.
struct MacPhotoActionShortcuts: NSViewRepresentable {
    var onDelete: (() -> Void)? = nil
    var onPrimaryAction: (() -> Void)? = nil

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }

    func updateNSView(_ view: ShortcutView, context: Context) {
        view.onDelete = onDelete
        view.onPrimaryAction = onPrimaryAction
    }

    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) {
        view.removeMonitor()
    }

    final class ShortcutView: NSView {
        var onDelete: (() -> Void)?
        var onPrimaryAction: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      self.window?.isKeyWindow == true,
                      !self.isHiddenOrHasHiddenAncestor, !self.visibleRect.isEmpty,
                      !(self.window?.firstResponder is NSTextView),
                      !(self.window?.firstResponder is NSTextField) else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if event.keyCode == 51, modifiers.isEmpty, let action = self.onDelete {
                    if !event.isARepeat { action() }
                    return nil
                }
                if event.keyCode == 36, modifiers == .command, let action = self.onPrimaryAction {
                    if !event.isARepeat { action() }
                    return nil
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#endif
