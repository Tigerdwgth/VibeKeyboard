import SwiftUI
import UniformTypeIdentifiers

// MARK: - SettingsView

struct SettingsView: View {
    @StateObject private var config = ConfigManager.shared

    var body: some View {
        TabView {
            RecordingSettingsTab(config: config)
                .tabItem {
                    Label("Recording", systemImage: "mic.fill")
                }

            FormattingSettingsTab(config: config)
                .tabItem {
                    Label("Formatting", systemImage: "textformat")
                }

            HotwordsSettingsTab(config: config)
                .tabItem {
                    Label("Hotwords", systemImage: "text.badge.star")
                }

            LLMSettingsTab(config: config)
                .tabItem {
                    Label("LLM", systemImage: "brain")
                }

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 400)
    }
}

// MARK: - Recording Tab

private struct RecordingSettingsTab: View {
    @ObservedObject var config: ConfigManager

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Silence Threshold")
                        Spacer()
                        Text("\(Int(config.silenceThreshold))")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $config.silenceThreshold, in: 100...2000, step: 50) {
                        Text("Silence Threshold")
                    }
                    Text("Higher values require louder speech to trigger recognition. Default: 500")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Silence Timeout")
                        Spacer()
                        Text(String(format: "%.1fs", config.silenceTimeout))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $config.silenceTimeout, in: 0.5...5.0, step: 0.5) {
                        Text("Silence Timeout")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Max Recording Duration")
                        Spacer()
                        Text("\(Int(config.maxDuration))s")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $config.maxDuration, in: 5...120, step: 5) {
                        Text("Max Duration")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Overlay Font Size")
                        Spacer()
                        Text("\(config.overlayFontSize)pt")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(config.overlayFontSize) },
                            set: { config.overlayFontSize = Int($0) }
                        ),
                        in: 10...24,
                        step: 1
                    ) {
                        Text("Font Size")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Formatting Tab

private struct FormattingSettingsTab: View {
    @ObservedObject var config: ConfigManager

    var body: some View {
        Form {
            Section {
                Toggle("Auto-spacing between CJK and Latin characters", isOn: $config.autoSpacing)

                Toggle("Auto-capitalize first letter of sentences", isOn: $config.capitalize)
            } header: {
                Text("Text Formatting")
            } footer: {
                Text("These rules are applied to the recognized text before pasting.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Hotwords Tab

private struct HotwordsSettingsTab: View {
    @ObservedObject var config: ConfigManager
    @State private var newHotword = ""
    @State private var showingImportPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Hotwords (\(config.hotwords.count))")
                    .font(.headline)
                Spacer()
                Button {
                    showingImportPicker = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .fileImporter(
                    isPresented: $showingImportPicker,
                    allowedContentTypes: [.plainText],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        if url.startAccessingSecurityScopedResource() {
                            config.importHotwords(from: url)
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Add new hotword
            HStack {
                TextField("Add hotword...", text: $newHotword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addHotword()
                    }

                Button("Add") {
                    addHotword()
                }
                .disabled(newHotword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            // List
            if config.hotwords.isEmpty {
                Spacer()
                Text("No hotwords configured.\nHotwords improve recognition accuracy for specific terms.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                List {
                    ForEach(config.hotwords, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button(role: .destructive) {
                                config.hotwords.removeAll { $0 == word }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { indexSet in
                        config.hotwords.remove(atOffsets: indexSet)
                    }
                }
            }
        }
    }

    private func addHotword() {
        let word = newHotword.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !config.hotwords.contains(word) else { return }
        config.hotwords.append(word)
        newHotword = ""
    }
}

// MARK: - LLM Tab

private struct LLMSettingsTab: View {
    @ObservedObject var config: ConfigManager

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("http://localhost:1234/v1", text: $config.llmApiUrl)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Leave empty for auto-select", text: $config.llmModel)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Optional (local models don't need one)", text: $config.llmApiKey)
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("LLM Polish (Optional)")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configure an OpenAI-compatible API to polish recognized text.")
                    Text("Leave the URL empty to use local regex rules only (recommended).")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About Tab

private struct AboutSettingsTab: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "mic.badge.xmark")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundColor(.accentColor)

            Text("VibeKeyboard")
                .font(.title)
                .fontWeight(.semibold)

            Text("Version \(version) (\(build))")
                .foregroundColor(.secondary)

            Text("macOS voice input powered by SenseVoice")
                .foregroundColor(.secondary)
                .font(.caption)

            Divider()
                .frame(width: 200)

            Link(destination: URL(string: "https://github.com/gsjBolt/voice-input-mac")!) {
                Label("GitHub Repository", systemImage: "link")
            }

            Text("Double-tap Option to start recording\nEnter to confirm and paste\nESC to cancel")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .font(.caption)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
#endif
