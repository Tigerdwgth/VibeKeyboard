// TextInserter.swift
// VibeKeyboard — Text insertion via pasteboard + simulated Cmd+V
//
// Strategy:
//   1. Write text to NSPasteboard
//   2. Try CGEvent-based Cmd+V (requires accessibility permission)
//   3. Fallback to AppleScript osascript

import Foundation
import AppKit
import Carbon.HIToolbox

/// Inserts text into the frontmost application by writing to the pasteboard
/// and simulating Cmd+V.
///
/// Conforms to TextInserterProtocol for ViewModel integration.
final class TextInserter: TextInserterProtocol {

    private let lock = NSLock()

    // MARK: - Public API

    /// Insert text into the current application.
    ///
    /// Writes to the system pasteboard, then simulates Cmd+V paste.
    /// Falls back to AppleScript if CGEvent method fails.
    func insertText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        guard setClipboard(trimmed) else {
            NSLog("[TextInserter] ERROR: Failed to write to clipboard")
            return
        }

        // Small delay to ensure pasteboard is updated
        Thread.sleep(forTimeInterval: 0.05)

        if Self.isAccessibilityTrusted() {
            if pasteCGEvent() {
                NSLog("[TextInserter] Pasted via CGEvent: %@", String(trimmed.prefix(50)))
                return
            }
            NSLog("[TextInserter] CGEvent paste failed, trying AppleScript...")
        }

        if pasteAppleScript() {
            NSLog("[TextInserter] Pasted via AppleScript: %@", String(trimmed.prefix(50)))
        } else {
            NSLog("[TextInserter] All paste methods failed. Text is on clipboard, user can Cmd+V manually.")
        }
    }

    // MARK: - Accessibility

    /// Check if the app has accessibility (trusted) permission.
    /// This is required for CGEvent-based keyboard simulation.
    static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Prompt the user to grant accessibility permission if not already granted.
    static func requestAccessibilityIfNeeded() {
        if !isAccessibilityTrusted() {
            NSLog("[TextInserter] Requesting accessibility permission...")
            _ = isAccessibilityTrusted(prompt: true)
        }
    }

    // MARK: - Clipboard

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

        // Key code for 'V' is 9
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }

        // Set Cmd modifier
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Post to the focused application
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return true
    }

    /// Simulate Cmd+V using AppleScript (fallback method).
    /// This goes through System Events and may show a permission dialog.
    private func pasteAppleScript() -> Bool {
        // First try: through the frontmost application's Edit menu
        let menuScript = """
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
        end tell
        tell application frontApp
            activate
            tell application "System Events"
                keystroke "v" using command down
            end tell
        end tell
        """

        if runAppleScript(menuScript) {
            return true
        }

        // Fallback: direct keystroke via System Events
        let directScript = """
        tell application "System Events" to keystroke "v" using command down
        """
        return runAppleScript(directScript)
    }

    /// Execute an AppleScript string via osascript.
    private func runAppleScript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("[TextInserter] osascript error: %@", error.localizedDescription)
            return false
        }
    }
}
