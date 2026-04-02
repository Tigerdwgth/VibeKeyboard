import SwiftUI

@main
struct VibeKeyboardApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = VibeKeyboardViewModel()

    var body: some Scene {
        // MARK: - Menubar Dropdown
        MenuBarExtra {
            MenuBarContentView(viewModel: viewModel)
        } label: {
            Label {
                Text("VibeKeyboard")
            } icon: {
                Image(systemName: viewModel.isRecording ? "record.circle.fill" : "mic.fill")
            }
        }

        // MARK: - Settings Window (Cmd+,)
        Settings {
            SettingsView()
        }
    }
}

// MARK: - Menubar Dropdown Content

struct MenuBarContentView: View {
    @ObservedObject var viewModel: VibeKeyboardViewModel

    var body: some View {
        // Status
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(viewModel.statusText)
            } icon: {
                statusIcon
            }
            .font(.system(size: 13))
        }

        // Current backend
        Text("Backend: \(viewModel.backendName)")
            .font(.system(size: 12))
            .foregroundColor(.secondary)

        // Hotword count
        Text("Hotwords: \(viewModel.hotwordCount)")
            .font(.system(size: 12))
            .foregroundColor(.secondary)

        Divider()

        // Settings
        Button("Settings...") {
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        // Quit
        Button("Quit VibeKeyboard") {
            viewModel.cleanup()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Helpers

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.appState {
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .recording:
            Image(systemName: "record.circle.fill")
                .foregroundColor(.red)
        case .processing:
            Image(systemName: "gear.circle.fill")
                .foregroundColor(.blue)
        case .loading:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.orange)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    /// Open the Settings window programmatically.
    private func openSettings() {
        // On macOS 14+ we can use SettingsLink, but for macOS 13 compat
        // we send the standard Preferences action.
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
