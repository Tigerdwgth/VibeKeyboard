// Polisher.swift
// VibeKeyboard — Text polishing (filler word removal + optional LLM polish)

import Foundation

// MARK: - Local filler word patterns

/// Filler words at the beginning
private let reFillerStart = try! NSRegularExpression(pattern: #"^[呃嗯啊额哦唉哎嗷]+[，,、\s]*"#)

/// Filler words in the middle between commas
private let reFillerMiddle = try! NSRegularExpression(pattern: #"[，,]\s*[呃嗯啊额哦]+\s*[，,]"#)

/// Multiple consecutive commas
private let reMultiComma = try! NSRegularExpression(pattern: #"[，,]{2,}"#)

/// Leading commas/spaces
private let reLeadingComma = try! NSRegularExpression(pattern: #"^[，,\s]+"#)

/// Trailing commas/spaces
private let reTrailingComma = try! NSRegularExpression(pattern: #"[，,\s]+$"#)

/// Sentence-ending punctuation characters
private let sentenceEndingPunctuation: Set<Character> = ["。", "？", "！", ".", "?", "!"]

// MARK: - TextPolisher

/// Text polisher that removes filler words and optionally uses LLM for refinement.
///
/// Conforms to TextPolisherProtocol for ViewModel integration.
final class TextPolisher: TextPolisherProtocol {

    // MARK: - Instance method (protocol conformance)

    /// Polish text: use LLM if configured, otherwise local regex.
    func polish(_ text: String) -> String {
        // Read LLM config snapshot (thread-safe)
        let cfg: ConfigManager.LLMConfig
        if Thread.isMainThread {
            cfg = ConfigManager.shared.llmConfig
        } else {
            cfg = DispatchQueue.main.sync { ConfigManager.shared.llmConfig }
        }

        guard cfg.enabled, !cfg.apiUrl.isEmpty else {
            return Self.polishLocal(text)
        }

        let config: [String: Any] = [
            "llm_api_url": cfg.apiUrl,
            "llm_api_key": cfg.apiKey,
            "llm_model": cfg.model,
            "llm_prompt": cfg.prompt,
        ]

        // Synchronous wrapper for async LLM call
        let semaphore = DispatchSemaphore(value: 0)
        var result = Self.polishLocal(text)

        Task.detached {
            result = await Self.polishWithLLM(text, config: config)
            semaphore.signal()
        }

        // Wait up to 15 seconds for LLM response
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            NSLog("[TextPolisher] LLM timeout, using local rules")
            return Self.polishLocal(text)
        }
        return result
    }

    // MARK: - Static Local Polish

    /// Remove filler words using local regex rules (fast, no network).
    static func polishLocal(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        // Apply filler removal patterns
        result = applyRegex(reFillerStart, to: result, replacement: "，")
        result = applyRegex(reFillerMiddle, to: result, replacement: "，")

        // Clean up punctuation artifacts
        result = applyRegex(reMultiComma, to: result, replacement: "，")
        result = applyRegex(reLeadingComma, to: result, replacement: "")
        result = applyRegex(reTrailingComma, to: result, replacement: "")

        // Ensure sentence ends with punctuation
        if let last = result.last, !sentenceEndingPunctuation.contains(last) {
            result += "。"
        }

        return result
    }

    // MARK: - LLM Polish

    /// Polish text using an OpenAI-compatible LLM API.
    static func polishWithLLM(_ text: String, config: [String: Any]) async -> String {
        let apiURL = config["llm_api_url"] as? String ?? "http://localhost:1234/v1"
        let apiKey = config["llm_api_key"] as? String ?? "lm-studio"
        let model = config["llm_model"] as? String ?? ""
        let promptTemplate = config["llm_prompt"] as? String ?? ""

        // Use custom prompt if available, substituting {text} placeholder
        let prompt: String
        if !promptTemplate.isEmpty && promptTemplate.contains("{text}") {
            prompt = promptTemplate.replacingOccurrences(of: "{text}", with: text)
        } else {
            prompt = """
            处理以下语音识别文本，严格遵守规则：

            规则：
            - 删除语气词（呃、嗯、啊、哎、额、哦）和口头禅（那个、就是、然后）
            - 严禁改写、换词、总结、添加任何内容，只能删除不能增改
            - 如果内容包含多个要点/需求/步骤，拆分成编号列表（1. 2. 3.），每条保留原话
            - 如果只有一个意思，直接输出删除语气词后的原文
            - 只输出结果，不要解释

            原文：\(text)
            处理后：
            """
        }

        let endpoint = apiURL.hasSuffix("/") ? "\(apiURL)chat/completions" : "\(apiURL)/chat/completions"

        guard let url = URL(string: endpoint) else {
            NSLog("[TextPolisher] Invalid LLM API URL: %@", endpoint)
            return polishLocal(text)
        }

        let requestBody: [String: Any] = [
            "model": model.isEmpty ? "default" : model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 1024,
            "temperature": 0.3
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            NSLog("[TextPolisher] Failed to serialize LLM request body")
            return polishLocal(text)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("[TextPolisher] LLM API returned status %d", statusCode)
                return polishLocal(text)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                NSLog("[TextPolisher] Failed to parse LLM response")
                return polishLocal(text)
            }

            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[TextPolisher] LLM polish done: %@... -> %@...",
                  String(text.prefix(30)), String(result.prefix(30)))
            return result

        } catch {
            NSLog("[TextPolisher] LLM request failed: %@, falling back to local", error.localizedDescription)
            return polishLocal(text)
        }
    }

    /// Convenience: pick local or LLM polish based on config.
    static func polish(_ text: String, config: [String: Any]) async -> String {
        let llmURL = config["llm_api_url"] as? String ?? ""
        if !llmURL.isEmpty {
            return await polishWithLLM(text, config: config)
        }
        return polishLocal(text)
    }

    // MARK: - Helpers

    private static func applyRegex(_ regex: NSRegularExpression, to text: String, replacement: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
