import AppKit
import AVFoundation

/// AppDelegate — handles lifecycle, activation policy, and NSStatusItem retention.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Strong reference to the status item so macOS GC never collects it.
    var statusItem: NSStatusItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular policy: both Dock icon and menubar icon visible.
        // MenuBarExtra already creates the status item, but we want the app
        // to also appear in the Dock for Cmd+Tab switching.
        NSApp.setActivationPolicy(.regular)
        requestMicrophonePermission()
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
            NSLog("[VibeKeyboard] Microphone permission already granted")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("[VibeKeyboard] Microphone permission \(granted ? "granted" : "denied")")
            }
        case .denied, .restricted:
            NSLog("[VibeKeyboard] Microphone permission denied/restricted — opening System Settings")
            DispatchQueue.main.async {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        @unknown default:
            break
        }
    }
}
