// ConfigManager.swift
// VibeKeyboard — Unified configuration management
//
// ObservableObject for SwiftUI bindings + JSON file persistence.
// Stores settings in ~/voice-input-mac/config/settings.json

import Foundation
import SwiftUI

/// Manages application configuration with JSON persistence and SwiftUI bindings.
final class ConfigManager: ObservableObject {

    static let shared = ConfigManager()

    private let configDir: URL
    private let settingsFile: URL
    private let hotwordsFile: URL

    // MARK: - App Support paths (used by HotwordManager)

    /// Application support directory for VibeKeyboard
    static let appSupportDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("voice-input-mac/config")
    }()

    /// Hotwords file path (public, for HotwordManager compatibility)
    static var hotwordsFilePath: URL {
        return appSupportDir.appendingPathComponent("hotwords.txt")
    }

    // MARK: - Recording

    @Published var silenceThreshold: Double {
        didSet { save() }
    }

    @Published var silenceTimeout: Double {
        didSet { save() }
    }

    @Published var maxDuration: Double {
        didSet { save() }
    }

    @Published var overlayFontSize: Int {
        didSet { save() }
    }

    // MARK: - Formatting

    @Published var autoSpacing: Bool {
        didSet { save() }
    }

    @Published var capitalize: Bool {
        didSet { save() }
    }

    // MARK: - LLM

    @Published var llmApiUrl: String {
        didSet { save() }
    }

    @Published var llmModel: String {
        didSet { save() }
    }

    @Published var llmApiKey: String {
        didSet { save() }
    }

    @Published var llmPrompt: String {
        didSet { save() }
    }

    // MARK: - ASR

    @Published var asrBackend: String {
        didSet { save() }
    }

    // MARK: - Hotwords

    @Published var hotwords: [String] {
        didSet { saveHotwords() }
    }

    // MARK: - Derived

    var formattingConfig: [String: Any] {
        [
            "auto_spacing": autoSpacing,
            "capitalize": capitalize,
        ]
    }

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configDir = home.appendingPathComponent("voice-input-mac/config")
        settingsFile = configDir.appendingPathComponent("settings.json")
        hotwordsFile = configDir.appendingPathComponent("hotwords.txt")

        // Set defaults
        silenceThreshold = 500
        silenceTimeout = 2.0
        maxDuration = 30
        overlayFontSize = 16
        autoSpacing = true
        capitalize = true
        llmApiUrl = ""
        llmModel = ""
        llmApiKey = ""
        llmPrompt = """
            处理以下语音识别文本，严格遵守规则：

            规则：
            - 删除语气词（呃、嗯、啊、哎、额、哦）和口头禅（那个、就是、然后）
            - 严禁改写、换词、总结、添加任何内容，只能删除不能增改
            - 如果内容包含多个要点/需求/步骤，拆分成编号列表（1. 2. 3.），每条保留原话
            - 如果只有一个意思，直接输出删除语气词后的原文
            - 只输出结果，不要解释

            原文：{text}
            处理后：
            """
        asrBackend = "sherpa-sensevoice"
        hotwords = []

        loadFromFile()
        loadHotwords()
    }

    // MARK: - File I/O

    private func loadFromFile() {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return }

        do {
            let data = try Data(contentsOf: settingsFile)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let v = dict["silence_threshold"] as? Double { silenceThreshold = v }
            if let v = dict["silence_timeout"] as? Double { silenceTimeout = v }
            if let v = dict["max_duration"] as? Double { maxDuration = v }
            if let v = dict["overlay_font_size"] as? Int { overlayFontSize = v }
            if let v = dict["asr_backend"] as? String { asrBackend = v }
            if let v = dict["llm_api_url"] as? String { llmApiUrl = v }
            if let v = dict["llm_model"] as? String { llmModel = v }
            if let v = dict["llm_api_key"] as? String { llmApiKey = v }
            if let v = dict["llm_prompt"] as? String { llmPrompt = v }

            if let formatting = dict["formatting"] as? [String: Any] {
                if let v = formatting["auto_spacing"] as? Bool { autoSpacing = v }
                if let v = formatting["capitalize"] as? Bool { capitalize = v }
            }
        } catch {
            NSLog("[ConfigManager] Failed to load settings: \(error)")
        }
    }

    func save() {
        let dict: [String: Any] = [
            "silence_threshold": silenceThreshold,
            "silence_timeout": silenceTimeout,
            "max_duration": maxDuration,
            "overlay_font_size": overlayFontSize,
            "asr_backend": asrBackend,
            "llm_api_url": llmApiUrl,
            "llm_model": llmModel,
            "llm_api_key": llmApiKey,
            "llm_prompt": llmPrompt,
            "formatting": [
                "auto_spacing": autoSpacing,
                "capitalize": capitalize,
            ] as [String: Any],
        ]

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsFile, options: .atomic)
        } catch {
            NSLog("[ConfigManager] Failed to save settings: \(error)")
        }
    }

    // MARK: - Hotwords I/O

    private func loadHotwords() {
        guard FileManager.default.fileExists(atPath: hotwordsFile.path) else { return }

        do {
            let content = try String(contentsOf: hotwordsFile, encoding: .utf8)
            hotwords = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        } catch {
            NSLog("[ConfigManager] Failed to load hotwords: \(error)")
        }
    }

    func saveHotwords() {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let content = hotwords.joined(separator: "\n") + "\n"
            try content.write(to: hotwordsFile, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[ConfigManager] Failed to save hotwords: \(error)")
        }
    }

    func importHotwords(from url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let newWords = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !hotwords.contains($0) }
            hotwords.append(contentsOf: newWords)
        } catch {
            NSLog("[ConfigManager] Failed to import hotwords: \(error)")
        }
    }
}
