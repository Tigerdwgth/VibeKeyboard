// HotkeyListener.swift
// VibeKeyboard — Global hotkey detection
//
// Detects:
//   - Double-tap Option (Alt) key: triggers recording
//   - ESC (keyCode 53): cancels recording
//   - Return/Enter (keyCode 36): confirms recording result

import Foundation
import AppKit

/// Listens for global keyboard events to control voice input.
///
/// Uses both global monitors (for events in other apps) and local monitors
/// (for events within our own app, since global monitors don't capture those).
///
/// Conforms to HotkeyListenerProtocol for ViewModel integration.
final class HotkeyListener: HotkeyListenerProtocol {

    // MARK: - Key Constants

    /// Option/Alt modifier flag
    private static let optionFlag: NSEvent.ModifierFlags = .option

    /// Key codes
    private static let keyEscape: UInt16 = 53
    private static let keyReturn: UInt16 = 36

    /// Maximum interval between two Option presses to count as double-tap
    private static let doubleTapInterval: TimeInterval = 0.35

    // MARK: - Callbacks

    /// Called when double-tap Option is detected
    var onPress: (() -> Void)?

    /// Called when ESC is pressed (cancel)
    var onCancel: (() -> Void)?

    /// Called when Return/Enter is pressed (confirm)
    var onConfirm: (() -> Void)?

    // MARK: - State

    private var lastOptionUpTime: TimeInterval = 0
    private var optionHeld = false
    private var monitors: [Any] = []

    // MARK: - Public API

    /// Start listening for keyboard events.
    /// Must be called from the main thread (requires NSApplication run loop).
    func start() {
        guard monitors.isEmpty else {
            NSLog("[HotkeyListener] Already started")
            return
        }

        // Global monitor: captures events when OTHER apps are focused
        if let globalFlags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event)
        }) {
            monitors.append(globalFlags)
        }

        if let globalKeyDown = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKeyDown(event)
        }) {
            monitors.append(globalKeyDown)
        }

        // Local monitor: captures events when OUR app is focused
        // Local monitors must return the event (or nil to consume it)
        if let localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }) {
            monitors.append(localFlags)
        }

        if let localKeyDown = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }) {
            monitors.append(localKeyDown)
        }

        NSLog("[HotkeyListener] Started: double-tap Option to record, Enter to confirm, ESC to cancel")
    }

    /// Stop listening for keyboard events.
    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        NSLog("[HotkeyListener] Stopped")
    }

    // MARK: - Event Handling

    /// Handle modifier key changes to detect double-tap Option.
    private func handleFlagsChanged(_ event: NSEvent) {
        let optionNow = event.modifierFlags.contains(.option)

        if optionNow && !optionHeld {
            // Option key pressed down
            optionHeld = true
        } else if !optionNow && optionHeld {
            // Option key released
            optionHeld = false

            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - lastOptionUpTime

            if elapsed < Self.doubleTapInterval && lastOptionUpTime > 0 {
                // Double-tap detected!
                lastOptionUpTime = 0 // Reset to prevent triple-tap
                NSLog("[HotkeyListener] Double-tap Option detected")
                onPress?()
            } else {
                lastOptionUpTime = now
            }
        }
    }

    /// Handle key down events for ESC and Return.
    private func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case Self.keyEscape:
            NSLog("[HotkeyListener] ESC pressed")
            onCancel?()

        case Self.keyReturn:
            NSLog("[HotkeyListener] Return/Enter pressed")
            onConfirm?()

        default:
            break
        }
    }

    deinit {
        stop()
    }
}
