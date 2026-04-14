// SherpaEngine.swift
// VibeKeyboard — ASR engine (sherpa-onnx SenseVoice backend)
//
// Real sherpa-onnx C API integration via offline recognizer.

import Foundation

// MARK: - SenseVoice tag cleaning regex
// SenseVoice outputs tags like <|zh|><|NEUTRAL|><|Speech|> that must be stripped.
private let senseVoiceTagPattern = try! NSRegularExpression(pattern: #"<\|[^|]*\|>"#)

/// ASR engine wrapping sherpa-onnx SenseVoice via the C API.
///
/// Conforms to SherpaEngineProtocol for ViewModel integration.
final class SherpaEngine: SherpaEngineProtocol {

    // MARK: - Configuration

    /// Path to the sherpa-onnx model directory.
    /// Priority: 1) Bundle resources (for .app), 2) ~/.cache fallback (dev/CLI).
    static let modelDir: String = {
        // Check if running as .app bundle with embedded model
        if let resourcePath = Bundle.main.resourcePath {
            let bundleModel = resourcePath + "/model.int8.onnx"
            if FileManager.default.fileExists(atPath: bundleModel) {
                NSLog("[SherpaEngine] Using bundle model dir: %@", resourcePath)
                return resourcePath
            }
        }
        // Fallback: ~/.cache for development / terminal runs
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cachePath = home + "/.cache/sherpa-onnx/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
        NSLog("[SherpaEngine] Using cache model dir: %@", cachePath)
        return cachePath
    }()

    /// HuggingFace model repo for download
    static let modelRepo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"

    // MARK: - State

    /// The offline recognizer handle from sherpa-onnx C API
    private var recognizer: OpaquePointer?
    private let lock = NSLock()

    /// Hotwords string (space-separated), used by Paraformer backend
    var hotwords: String = ""

    /// Progress callback for model loading/downloading
    var onProgress: ((String) -> Void)?

    // MARK: - Public API

    /// Protocol conformance: computed property for readiness check.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recognizer != nil
    }

    /// Protocol conformance: the backend name for display.
    var currentBackendName: String {
        return "SenseVoice-ONNX"
    }

    /// Load the ASR model. Call once at startup.
    func loadModel() {
        lock.lock()
        defer { lock.unlock() }

        onProgress?("Loading SenseVoice-ONNX model...")
        NSLog("[SherpaEngine] Loading model from %@", Self.modelDir)

        let modelPath = Self.modelDir + "/model.int8.onnx"
        let tokensPath = Self.modelDir + "/tokens.txt"

        // Verify files exist
        guard FileManager.default.fileExists(atPath: modelPath) else {
            NSLog("[SherpaEngine] ERROR: model not found at %@", modelPath)
            onProgress?("Error: model file not found")
            return
        }
        guard FileManager.default.fileExists(atPath: tokensPath) else {
            NSLog("[SherpaEngine] ERROR: tokens not found at %@", tokensPath)
            onProgress?("Error: tokens file not found")
            return
        }

        // Create config — zero-initialize, then fill SenseVoice fields
        var config = SherpaOnnxOfflineRecognizerConfig()
        // Use memset via withUnsafeMutablePointer to guarantee zero init
        withUnsafeMutablePointer(to: &config) { ptr in
            memset(ptr, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)
        }

        // Feature config
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80

        // Model config — all const char* must be passed as C strings that
        // stay alive through the SherpaOnnxCreateOfflineRecognizer call.
        // We use withCString closures nested to keep them alive.
        let language = ConfigManager.readSync { $0.asrLanguage }
        NSLog("[SherpaEngine] Language setting: %@", language)

        let rec = modelPath.withCString { cModelPath in
            tokensPath.withCString { cTokensPath in
                language.withCString { cLanguage in
                    "cpu".withCString { cProvider in
                        "greedy_search".withCString { cDecoding -> OpaquePointer? in
                            config.model_config.sense_voice.model = cModelPath
                            config.model_config.sense_voice.language = cLanguage
                            config.model_config.sense_voice.use_itn = 1
                            config.model_config.tokens = cTokensPath
                            config.model_config.num_threads = 2
                            config.model_config.debug = 1
                            config.model_config.provider = cProvider
                            config.decoding_method = cDecoding

                            let ptr = SherpaOnnxCreateOfflineRecognizer(&config)
                            return ptr
                        }
                    }
                }
            }
        }

        if let rec = rec {
            self.recognizer = rec
            onProgress?("SenseVoice-ONNX ready")
            NSLog("[SherpaEngine] Model loaded successfully")
        } else {
            NSLog("[SherpaEngine] ERROR: SherpaOnnxCreateOfflineRecognizer returned nil")
            onProgress?("Error: failed to create recognizer")
        }
    }

    deinit {
        if let rec = recognizer {
            SherpaOnnxDestroyOfflineRecognizer(rec)
        }
    }

    // MARK: - Transcription

    /// Protocol conformance: transcribe (blocking).
    func transcribe(audioData: Data) -> String? {
        return transcribeAudio(audioData: audioData, blocking: true)
    }

    /// Transcribe with blocking option.
    func transcribeAudio(audioData: Data, blocking: Bool = true) -> String? {
        guard recognizer != nil else { return nil }

        // Minimum audio length check: 0.3 seconds at 16kHz, Int16 = 9600 bytes
        let minBytes = Int(16000 * 0.3) * 2
        guard audioData.count >= minBytes else { return nil }

        if !blocking {
            guard lock.try() else { return nil }
            defer { lock.unlock() }
            return _doTranscribe(audioData: audioData)
        } else {
            lock.lock()
            defer { lock.unlock() }
            return _doTranscribe(audioData: audioData)
        }
    }

    // MARK: - Private

    private func _doTranscribe(audioData: Data) -> String {
        guard let rec = recognizer else { return "" }

        let durationSeconds = Double(audioData.count) / Double(16000 * 2)
        NSLog("[SherpaEngine] Transcribing %.2fs of audio (%d bytes)", durationSeconds, audioData.count)

        // Convert Int16 PCM to Float32 normalized to [-1, 1]
        let sampleCount = audioData.count / 2
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        audioData.withUnsafeBytes { rawBuf in
            let int16Buf = rawBuf.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floatSamples[i] = Float(int16Buf[i]) / 32768.0
            }
        }

        // Create stream, accept waveform, decode, get result
        guard let stream = SherpaOnnxCreateOfflineStream(rec) else {
            NSLog("[SherpaEngine] ERROR: Failed to create offline stream")
            return ""
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        floatSamples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, 16000, buf.baseAddress, Int32(sampleCount))
        }

        SherpaOnnxDecodeOfflineStream(rec, stream)

        guard let resultPtr = SherpaOnnxGetOfflineStreamResult(stream) else {
            NSLog("[SherpaEngine] ERROR: Failed to get offline stream result")
            return ""
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(resultPtr) }

        let rawText: String
        if let textPtr = resultPtr.pointee.text {
            rawText = String(cString: textPtr)
        } else {
            rawText = ""
        }

        NSLog("[SherpaEngine] Raw result: %@", rawText)
        let cleaned = cleanSenseVoiceTags(rawText)
        NSLog("[SherpaEngine] Cleaned result: %@", cleaned)
        return cleaned
    }

    // MARK: - Hotword Inference (Python subprocess)

    /// Path to the hotword model (ModelScope SenseVoiceSmall_hotword)
    private static let hotwordModelDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // ModelScope cache path
        let candidates = [
            home + "/.cache/modelscope/hub/dengcunqin/SenseVoiceSmall_hotword",
            home + "/.cache/modelscope/dengcunqin/SenseVoiceSmall_hotword",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path + "/model.onnx") {
                return path
            }
        }
        return candidates[0]
    }()

    /// Python executable in the conda environment
    private static let pythonPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let condaPython = home + "/miniconda3/envs/voice-input/bin/python3"
        if FileManager.default.fileExists(atPath: condaPython) {
            return condaPython
        }
        return "/usr/bin/python3"
    }()

    /// Path to the hotword inference script
    private static let hotwordScript: String = {
        // Check bundle first, then source tree
        if let bundlePath = Bundle.main.path(forResource: "hotword_infer", ofType: "py") {
            return bundlePath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/voice-input-mac/swift/ASR/hotword_infer.py"
    }()

    /// Check if hotword model is available
    var isHotwordAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.hotwordModelDir + "/model.onnx")
    }

    /// Transcribe using the hotword model via Python subprocess.
    /// Falls back to sherpa-onnx if Python inference fails.
    func transcribeWithHotwords(audioData: Data, hotwords: String, language: String) -> String? {
        guard isHotwordAvailable else {
            FileLogger.log("[SherpaEngine] Hotword model not found, falling back to standard")
            return transcribe(audioData: audioData)
        }

        let durationSeconds = Double(audioData.count) / Double(16000 * 2)
        FileLogger.log("[SherpaEngine] Hotword transcription: \(String(format: "%.1f", durationSeconds))s, hotwords=\(hotwords)")

        // Write PCM to temp file
        let tmpPath = NSTemporaryDirectory() + "vk_audio_\(ProcessInfo.processInfo.processIdentifier).pcm"
        do {
            try audioData.write(to: URL(fileURLWithPath: tmpPath))
        } catch {
            FileLogger.log("[SherpaEngine] Failed to write temp audio: \(error)")
            return transcribe(audioData: audioData)
        }
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pythonPath)
        process.arguments = [
            Self.hotwordScript,
            "--model_dir", Self.hotwordModelDir,
            "--hotwords", hotwords,
            "--score", "1.0",
            "--language", language,
            "--audio", tmpPath,
        ]

        // Set conda environment
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let condaLib = home + "/miniconda3/envs/voice-input/lib"
        env["DYLD_LIBRARY_PATH"] = condaLib
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                FileLogger.log("[SherpaEngine] Hotword Python error: \(errStr)")
                return transcribe(audioData: audioData)
            }

            if text.isEmpty {
                return transcribe(audioData: audioData)
            }

            FileLogger.log("[SherpaEngine] Hotword result: \(text)")
            return cleanSenseVoiceTags(text)
        } catch {
            FileLogger.log("[SherpaEngine] Hotword process failed: \(error)")
            return transcribe(audioData: audioData)
        }
    }

    /// Remove SenseVoice special tags like <|zh|>, <|NEUTRAL|>, <|Speech|>, <|endoftext|>
    func cleanSenseVoiceTags(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = senseVoiceTagPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
