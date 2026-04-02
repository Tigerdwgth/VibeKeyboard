// Formatter.swift
// VibeKeyboard — Text formatting (CJK-English spacing, capitalization, custom replacements)

import Foundation

// MARK: - Regex patterns for CJK-English auto spacing

/// CJK character followed by alphanumeric -> insert space
private let reCJKAlpha = try! NSRegularExpression(pattern: #"([\u4e00-\u9fff])([a-zA-Z0-9])"#)

/// Alphanumeric followed by CJK character -> insert space
private let reAlphaCJK = try! NSRegularExpression(pattern: #"([a-zA-Z0-9])([\u4e00-\u9fff])"#)

/// Lowercase letter after sentence-ending punctuation + space -> capitalize
private let reSentenceStart = try! NSRegularExpression(pattern: #"(?<=[.!?]\s)([a-z])"#)

/// Formats ASR output text with CJK-English spacing, capitalization,
/// and custom replacement rules.
///
/// Conforms to TextFormatterProtocol for ViewModel integration.
final class TextFormatter: TextFormatterProtocol {

    // MARK: - Configuration

    /// Whether to auto-insert spaces between CJK and English text
    var autoSpacing: Bool

    /// Whether to capitalize sentence starts
    var capitalize: Bool

    /// Custom text replacements (pattern -> replacement)
    var replacements: [String: String]

    // MARK: - Init

    init(config: [String: Any] = [:]) {
        self.autoSpacing = config["auto_spacing"] as? Bool ?? true
        self.capitalize = config["capitalize"] as? Bool ?? true
        self.replacements = config["replacements"] as? [String: String] ?? [:]
    }

    // MARK: - Public API

    /// Format ASR output text.
    ///
    /// Applies in order:
    ///   1. CJK-English auto spacing
    ///   2. Sentence capitalization
    ///   3. Custom replacements
    func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        // 1. CJK-English auto spacing
        if autoSpacing {
            result = applyCJKSpacing(result)
        }

        // 2. Sentence capitalization
        if capitalize {
            result = applyCapitalization(result)
        }

        // 3. Custom replacements
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(of: pattern, with: replacement)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    /// Insert spaces between CJK characters and alphanumeric characters.
    private func applyCJKSpacing(_ text: String) -> String {
        var result = text
        let range = NSRange(result.startIndex..., in: result)

        // CJK followed by alpha
        result = reCJKAlpha.stringByReplacingMatches(
            in: result, range: range, withTemplate: "$1 $2"
        )

        let range2 = NSRange(result.startIndex..., in: result)
        // Alpha followed by CJK
        result = reAlphaCJK.stringByReplacingMatches(
            in: result, range: range2, withTemplate: "$1 $2"
        )

        return result
    }

    /// Capitalize the first letter and letters after sentence-ending punctuation.
    private func applyCapitalization(_ text: String) -> String {
        var result = text

        // Capitalize first character if it's a letter
        if let first = result.first, first.isLetter && first.isLowercase {
            result = first.uppercased() + String(result.dropFirst())
        }

        // Manual approach for sentence capitalization
        result = capitalizeSentenceStarts(result)

        return result
    }

    /// Manually capitalize lowercase letters that follow ". ", "! ", or "? "
    private func capitalizeSentenceStarts(_ text: String) -> String {
        var chars = Array(text)
        let count = chars.count

        var i = 0
        while i < count {
            if i >= 2 {
                let prev2 = chars[i - 2]
                let prev1 = chars[i - 1]
                let current = chars[i]

                if (prev2 == "." || prev2 == "!" || prev2 == "?") &&
                   prev1 == " " &&
                   current.isLowercase {
                    chars[i] = Character(current.uppercased())
                }
            }
            i += 1
        }

        return String(chars)
    }
}
