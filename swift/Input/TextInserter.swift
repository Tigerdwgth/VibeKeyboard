// TextInserter.swift
// VibeKeyboard — Text insertion via pasteboard + simulated Cmd+V
//
// Strategy:
//   1. Save previous clipboard, write text to NSPasteboard
//   2. Activate target app, poll until it becomes frontmost
//   3. Try CGEvent-based Cmd+V (requires accessibility permission)
//   4. Fallback to AppleScript keystroke via System Events
//   5. Fallback to NSAppleScript (in-process, avoids osascript spawn)
//   6. Restore previous clipboard after a delay

import Foundation
import AppKit
import Carbon.HIToolbox

/// Inserts text into the frontmost application by writing to the pasteboard
/// and simulating Cmd+V.
///
/// Conforms to TextInserterProtocol for ViewModel integration.
final class TextInserter: TextInserterProtocol {

    private let lock = NSLock()

    /// Maximum time to wait for target app to become frontmost (seconds).
    private static let activationTimeout: TimeInterval = 0.8

    /// Polling interval when waiting for activation (seconds).
    private static let activationPollInterval: TimeInterval = 0.03

    /// Delay after paste before restoring clipboard (seconds).
    private static let clipboardRestoreDelay: TimeInterval = 0.5

    // MARK: - Public API

    /// Insert text into the current application.
    func insertText(_ text: String) {
        insertText(text, activating: nil)
    }

    /// Insert text, first activating the specified target application.
    func insertText(_ text: String, activating targetApp: NSRunningApplication?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            FileLogger.log("[TextInserter] Skipped: empty text after trimming")
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let trusted = Self.isAccessibilityTrusted()
        FileLogger.log("[TextInserter] === Begin paste === accessibility=\(trusted ? "YES" : "NO"), text=\(String(trimmed.prefix(60)))")

        // Step 1: Activate the target app and wait until it is frontmost
        if let target = targetApp, !target.isTerminated {
            let activated = activateAndWait(target)
            if !activated {
                FileLogger.log("[TextInserter] WARNING: target app may not be frontmost, attempting paste anyway")
            }
        } else if targetApp != nil {
            FileLogger.log("[TextInserter] WARNING: target app is nil or terminated")
        }

        // Log the actual frontmost app for diagnostics
        if let front = NSWorkspace.shared.frontmostApplication {
            FileLogger.log("[TextInserter] Frontmost app: \(front.localizedName ?? "?") (pid=\(front.processIdentifier))")
        }

        // Step 2: Save previous clipboard and write new text
        let previousClipboard = savePasteboard()
        guard setClipboard(trimmed) else {
            FileLogger.log("[TextInserter] ERROR: Failed to write to clipboard")
            return
        }
        FileLogger.log("[TextInserter] Clipboard set OK, changeCount=\(NSPasteboard.general.changeCount)")

        // Small delay to ensure pasteboard is synchronized
        Thread.sleep(forTimeInterval: 0.05)

        // Step 3: Try paste methods in order of preference
        var pasted = false

        // Method 1: CGEvent (fastest, most reliable when accessibility is granted)
        if trusted {
            if pasteCGEvent() {
                Thread.sleep(forTimeInterval: 0.1)
                FileLogger.log("[TextInserter] Pasted via CGEvent: \(String(trimmed.prefix(50)))")
                pasted = true
            } else {
                FileLogger.log("[TextInserter] CGEvent paste failed (event creation error)")
            }
        } else {
            FileLogger.log("[TextInserter] Skipping CGEvent: no accessibility permission")
        }

        // Method 2: AppleScript via System Events keystroke
        if !pasted {
            FileLogger.log("[TextInserter] Trying AppleScript keystroke via System Events...")
            if pasteAppleScriptKeystroke() {
                Thread.sleep(forTimeInterval: 0.1)
                FileLogger.log("[TextInserter] Pasted via AppleScript keystroke: \(String(trimmed.prefix(50)))")
                pasted = true
            } else {
                FileLogger.log("[TextInserter] AppleScript keystroke failed")
            }
        }

        // Method 3: NSAppleScript in-process (avoids osascript process spawn overhead)
        if !pasted {
            FileLogger.log("[TextInserter] Trying NSAppleScript in-process...")
            if pasteNSAppleScript() {
                Thread.sleep(forTimeInterval: 0.1)
                FileLogger.log("[TextInserter] Pasted via NSAppleScript: \(String(trimmed.prefix(50)))")
                pasted = true
            } else {
                FileLogger.log("[TextInserter] NSAppleScript failed")
            }
        }

        if !pasted {
            FileLogger.log("[TextInserter] ALL paste methods failed. Text is on clipboard for manual Cmd+V.")
            return
        }

        // Step 4: Restore previous clipboard after a delay
        restorePasteboardAfterDelay(previousClipboard)

        FileLogger.log("[TextInserter] === Paste complete ===")
    }

    // MARK: - Accessibility

    /// Check if the app has accessibility (trusted) permission.
    static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Prompt the user to grant accessibility permission if not already granted.
    static func requestAccessibilityIfNeeded() {
        if !isAccessibilityTrusted() {
            FileLogger.log("[TextInserter] Requesting accessibility permission...")
            _ = isAccessibilityTrusted(prompt: true)
        }
    }

    // MARK: - App Activation

    /// Activate the target app and poll until it becomes frontmost or timeout.
    private func activateAndWait(_ target: NSRunningApplication) -> Bool {
        let appName = target.localizedName ?? "pid=\(target.processIdentifier)"
        FileLogger.log("[TextInserter] Activating target: \(appName) (pid=\(target.processIdentifier))")

        activateApp(target)

        // Poll until the target app is frontmost
        let startTime = Date()
        let deadline = startTime.addingTimeInterval(Self.activationTimeout)
        var attempts = 0
        while Date() < deadline {
            attempts += 1
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier == target.processIdentifier {
                let elapsed = Date().timeIntervalSince(startTime) * 1000
                FileLogger.log("[TextInserter] Target app became frontmost after \(attempts) polls (\(Int(elapsed))ms)")
                return true
            }
            Thread.sleep(forTimeInterval: Self.activationPollInterval)
        }

        // One more try: some apps need a second activation call
        activateApp(target)
        Thread.sleep(forTimeInterval: 0.1)

        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier == target.processIdentifier {
            FileLogger.log("[TextInserter] Target app became frontmost after retry activation")
            return true
        }

        let frontName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        FileLogger.log("[TextInserter] WARNING: Activation timeout (\(Self.activationTimeout)s, \(attempts) polls). Target=\(appName), Frontmost=\(frontName)")
        return false
    }

    /// Activate a running application, using the best available API.
    private func activateApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate(from: NSRunningApplication.current)
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

    // MARK: - Clipboard

    /// Save the current pasteboard content for later restoration.
    private func savePasteboard() -> [NSPasteboard.PasteboardType: Data]? {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types else { return nil }

        var saved: [NSPasteboard.PasteboardType: Data] = [:]
        for type in types {
            if let data = pasteboard.data(forType: type) {
                saved[type] = data
            }
        }
        return saved.isEmpty ? nil : saved
    }

    /// Restore the pasteboard content after a delay.
    private func restorePasteboardAfterDelay(_ saved: [NSPasteboard.PasteboardType: Data]?) {
        guard let saved = saved, !saved.isEmpty else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.clipboardRestoreDelay) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            for (type, data) in saved {
                pasteboard.setData(data, forType: type)
            }
            FileLogger.log("[TextInserter] Previous clipboard restored")
        }
    }

    /// Write text to the system pasteboard (NSPasteboard).
    private func setClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    // MARK: - Paste Methods

    /// Simulate Cmd+V using CGEvent (requires accessibility permission).
    private func pasteCGEvent() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)

        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            FileLogger.log("[TextInserter] CGEvent creation failed (nil events)")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(20_000) // 20ms
        keyUp.post(tap: .cghidEventTap)

        return true
    }

    /// Simulate Cmd+V using AppleScript keystroke via System Events.
    private func pasteAppleScriptKeystroke() -> Bool {
        let script = """
        tell application "System Events" to keystroke "v" using command down
        """
        return runAppleScript(script)
    }

    /// Simulate Cmd+V using NSAppleScript (in-process, no osascript spawn).
    private func pasteNSAppleScript() -> Bool {
        let scriptSource = """
        tell application "System Events" to keystroke "v" using command down
        """
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: scriptSource)
        script?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            FileLogger.log("[TextInserter] NSAppleScript error: \(error)")
            return false
        }
        return true
    }

    /// Execute an AppleScript string via osascript process.
    private func runAppleScript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? "(no output)"
                FileLogger.log("[TextInserter] osascript failed (exit \(process.terminationStatus)): \(errStr)")
            }
            return process.terminationStatus == 0
        } catch {
            FileLogger.log("[TextInserter] osascript launch error: \(error.localizedDescription)")
            return false
        }
    }
}
