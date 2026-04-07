import AppKit
import AVFoundation

/// AppDelegate — handles lifecycle, activation policy, and NSStatusItem retention.
///
/// Activation policy management:
///   - Default is `.accessory` (no Dock icon, no app menu — proper menubar app behavior).
///   - When Settings window opens, temporarily switch to `.regular` so the window
///     can appear in front and receive focus properly.
///   - When the last window closes, switch back to `.accessory`.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Strong reference to the status item so macOS GC never collects it.
    var statusItem: NSStatusItem?

    /// Observer for window visibility changes.
    private var windowObservers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileLogger.truncate()
        NSApp.setActivationPolicy(.accessory)
        requestMicrophonePermission()
        let hasAccessibility = TextInserter.isAccessibilityTrusted()
        FileLogger.log("[AppDelegate] Launched, accessibility=\(hasAccessibility ? "YES" : "NO")")

        // If accessibility is missing, guide the user to grant it
        if !hasAccessibility {
            promptAccessibilityPermission()
        }

        // Remove unwanted system-injected menus (Debug, Instruments, etc.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.removeUnwantedMenus()
        }

        // Monitor window show/hide to manage activation policy.
        // When a regular window (Settings) appears, switch to .regular policy
        // so it can be focused properly. When all windows close, revert.
        let showObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            // Only care about titled windows (Settings), not floating/overlay
            if window.styleMask.contains(.titled) {
                NSLog("[VibeKeyboard] Settings window became key, switching to .regular policy")
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        windowObservers.append(showObserver)

        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            if window.styleMask.contains(.titled) {
                // Check if this is the last titled window
                let titledWindows = NSApp.windows.filter {
                    $0.styleMask.contains(.titled) && $0.isVisible && $0 !== window
                }
                if titledWindows.isEmpty {
                    NSLog("[VibeKeyboard] Last settings window closing, reverting to .accessory policy")
                    // Small delay to let the close animation finish
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
        windowObservers.append(closeObserver)

        NSLog("[VibeKeyboard] AppDelegate launched, accessibility=%{public}@",
              TextInserter.isAccessibilityTrusted() ? "YES" : "NO")
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
        // Remove window observers
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()

        // Cleanup is driven by VibeKeyboardViewModel.cleanup()
        // which the @main App calls in its onDisappear / scene phase handler.
        NSLog("[VibeKeyboard] applicationWillTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menubar apps should keep running even when all windows are closed.
        return false
    }

    // MARK: - Accessibility Permission

    /// Show an alert and open System Settings when accessibility permission is missing.
    private func promptAccessibilityPermission() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Trigger the system permission prompt
            _ = TextInserter.isAccessibilityTrusted(prompt: true)

            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = """
            VibeKeyboard 需要辅助功能权限才能自动粘贴文字。

            请在系统设置中：
            1. 找到 VibeKeyboard
            2. 打开其开关

            如果列表中没有 VibeKeyboard，点击 "+" 添加：
            ~/Applications/VibeKeyboard.app
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")

            // Temporarily switch to regular so the alert is visible
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Open Accessibility settings pane
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }

            // Switch back to accessory after alert
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
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
