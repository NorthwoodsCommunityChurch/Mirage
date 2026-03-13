import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install crash handlers as early as possible
        CrashReporter.shared.install()
        AppLogger.shared.log("App launched")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLogger.shared.log("App terminating")
        guard let appState else { return .terminateNow }

        // If nothing is mounted, quit immediately
        let hasActiveMounts = appState.mountStatuses.values.contains { $0.isActive }
        guard hasActiveMounts else {
            appState.cleanup()
            return .terminateNow
        }

        // Clean up mounts and wait for rclone to flush pending VFS write-backs.
        // Poll for process exit instead of sleeping a fixed duration.
        Task { @MainActor in
            appState.cleanup()
            // Wait up to 5 seconds for processes to exit
            for _ in 0..<50 {
                if appState.processManager.runningMounts.isEmpty { break }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
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
