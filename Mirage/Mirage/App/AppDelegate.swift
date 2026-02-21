import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initial setup is triggered by the app's onAppear
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }

        // Clean up all mounts before quitting.
        // terminateAll() sends SIGTERM to rclone processes, which triggers
        // graceful unmount including flushing any pending VFS write-backs.
        // We wait up to 10 seconds to allow writes to complete before letting
        // the app terminate (at which point SIGKILL fires as a backstop).
        Task { @MainActor in
            appState.cleanup()
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Re-open main window when dock icon is clicked with no visible windows
            for window in NSApp.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(self)
                    break
                }
            }
        }
        return true
    }
}
