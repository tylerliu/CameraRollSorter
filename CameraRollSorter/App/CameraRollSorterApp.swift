//
//  CameraRollSorterApp.swift
//  CameraRollSorter
//
//  Created by Tyler on 2026-09-17.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct CameraRollSorterApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            CleanupHomeView()
        }
    }
}

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif
