// HotwordManager.swift
// VibeKeyboard — Hotword list management for ASR
//
// Hotwords improve ASR accuracy for domain-specific terms.
// File format: one hotword per line, lines starting with # are comments.

import Foundation

/// Manages a list of hotwords stored in a text file.
///
/// Hotwords are used by ASR engines (like FunASR Paraformer) to improve
/// recognition accuracy for specific terms.
final class HotwordManager {

    // MARK: - Properties

    /// Current hotword list
    private(set) var hotwords: [String] = []

    /// Path to the hotwords file
    let filePath: URL

    // MARK: - Init

    /// Initialize with a path to the hotwords file.
    /// Loads existing hotwords from file if it exists.
    init(filePath: URL) {
        self.filePath = filePath
        load()
    }

    /// Convenience initializer with a string path.
    convenience init(path: String) {
        self.init(filePath: URL(fileURLWithPath: path))
    }

    // MARK: - Load / Save

    /// Load hotwords from the file.
    func load() {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            hotwords = []
            return
        }

        do {
            let content = try String(contentsOf: filePath, encoding: .utf8)
            hotwords = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            NSLog("[HotwordManager] Loaded %d hotwords from %@", hotwords.count, filePath.path)
        } catch {
            NSLog("[HotwordManager] ERROR: Failed to load hotwords: %@", error.localizedDescription)
            hotwords = []
        }
    }

    /// Save hotwords to the file.
    func save() {
        do {
            // Ensure parent directory exists
            let dir = filePath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let content = hotwords.joined(separator: "\n") + "\n"
            try content.write(to: filePath, atomically: true, encoding: .utf8)
            NSLog("[HotwordManager] Saved %d hotwords", hotwords.count)
        } catch {
            NSLog("[HotwordManager] ERROR: Failed to save hotwords: %@", error.localizedDescription)
        }
    }

    // MARK: - CRUD

    /// Add a hotword (no duplicates).
    func add(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !hotwords.contains(trimmed) else { return }
        hotwords.append(trimmed)
        save()
    }

    /// Remove a hotword.
    func remove(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        hotwords.removeAll { $0 == trimmed }
        save()
    }

    /// Replace the entire hotword list.
    func setHotwords(_ words: [String]) {
        hotwords = words
        save()
    }

    /// Get hotwords as a space-separated string (FunASR format).
    func getHotwordsString() -> String {
        return hotwords.joined(separator: " ")
    }

    // MARK: - Import

    /// Import hotwords from an external file (merges, no duplicates).
    func importFromFile(at path: URL) throws {
        let content = try String(contentsOf: path, encoding: .utf8)
        let newWords = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        for word in newWords {
            if !hotwords.contains(word) {
                hotwords.append(word)
            }
        }
        save()
    }
}
