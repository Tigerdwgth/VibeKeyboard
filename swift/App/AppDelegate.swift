import AppKit
import AVFoundation

/// AppDelegate — handles lifecycle, activation policy, and NSStatusItem retention.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Strong reference to the status item so macOS GC never collects it.
    var statusItem: NSStatusItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        requestMicrophonePermission()

        // Remove unwanted system-injected menus (Debug, Instruments, etc.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.removeUnwantedMenus()
        }
    }

    /// Remove system-injected menus like "Instruments", "Debug" that macOS adds to ad-hoc signed apps.
    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let unwanted: Set<String> = ["Instruments", "Debug"]
        for item in mainMenu.items.reversed() {
            if let title = item.submenu?.title, unwanted.contains(title) {
                mainMenu.removeItem(item)
                NSLog("[VibeKeyboard] Removed unwanted menu: %@", title)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup is driven by VibeKeyboardViewModel.cleanup()
        // which the @main App calls in its onDisappear / scene phase handler.
        NSLog("[VibeKeyboard] applicationWillTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menubar apps should keep running even when all windows are closed.
        return false
    }

    // MARK: - Microphone Permission

    private func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            NSLog("[VibeKeyboard] Microphone permission OK")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("[VibeKeyboard] Microphone permission \(granted ? "granted" : "denied")")
            }
        case .denied, .restricted:
            // Don't auto-open settings — user already made their choice
            NSLog("[VibeKeyboard] Microphone permission denied/restricted")
        @unknown default:
            break
        }
    }
}
