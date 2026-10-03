import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Small cross-platform shims so shared feature views don't need `#if os(...)`
/// for every iOS-only modifier. Large platform differences (zoom view, limited
/// library picker) live in `Platform/iOS` and `Platform/macOS` instead.
enum PlatformSettings {
    /// Where to send the user to change Photos access: the app's page in iOS
    /// Settings, or Privacy & Security › Photos in macOS System Settings.
    static var photosPrivacyURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
        #endif
    }

    /// Whether the system "limited library" picker exists (iOS only).
    static var supportsLimitedLibraryPicker: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Leading bar item: `.topBarLeading` on iOS, `.navigation` on macOS.
    static var platformLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// Trailing bar item: `.topBarTrailing` on iOS, `.primaryAction` on macOS.
    static var platformTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    /// Inline navigation title on iOS; no-op on macOS (titles live in the window toolbar).
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.insetGrouped` list on iOS; `.inset` on macOS.
    func groupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    /// Always-visible navigation bar background on iOS; no-op on macOS.
    func visibleNavigationBarBackground() -> some View {
        #if os(iOS)
        toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Touch-friendly wheels on iOS; editable date segments and a stepper on Mac.
    func scanDatePickerStyle() -> some View {
        #if os(iOS)
        datePickerStyle(.wheel)
        #else
        datePickerStyle(.stepperField)
        #endif
    }

    /// Swipeable page-style `TabView` on iOS. macOS has no page style, so this
    /// is a no-op there (the default tab style).
    /// TODO(macOS): replace with a real single-photo pager (arrow keys / buttons).
    func pagedTabViewStyle(showsIndex: Bool) -> some View {
        #if os(iOS)
        tabViewStyle(.page(indexDisplayMode: showsIndex ? .automatic : .never))
        #else
        self
        #endif
    }

    /// Full-screen cover on iOS; a separate resizable viewer window on macOS.
    func platformFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        background {
            MacViewerWindow(isPresented: isPresented, content: content)
                .frame(width: 0, height: 0)
        }
        #endif
    }
}

/// Readable action-bar typography and button sizing for each platform.
enum PhotoActionBarLayout {
    static var spacing: CGFloat {
        #if os(macOS)
        0
        #else
        8
        #endif
    }

    static var titleFont: Font {
        #if os(macOS)
        .system(size: 16, weight: .semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }

    static var detailFont: Font {
        #if os(macOS)
        .system(size: 12)
        #else
        .caption
        #endif
    }
}

extension View {
    func photoActionButtonLabelSizing() -> some View {
        #if os(macOS)
        self
            .font(.system(size: 16, weight: .semibold))
            .frame(minWidth: 140, minHeight: 26)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        #else
        self
        #endif
    }

    func photoActionBarSizing() -> some View {
        #if os(macOS)
        self
            .font(.system(size: 16))
            .controlSize(.large)
            .frame(minHeight: 44)
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
        #else
        self
            .padding(.horizontal)
            .padding(.bottom, 6)
        #endif
    }
}
