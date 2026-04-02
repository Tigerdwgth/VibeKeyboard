// SherpaEngine.swift
// VibeKeyboard — ASR engine (sherpa-onnx SenseVoice backend)
//
// TODO: Replace mock implementation with real sherpa-onnx C API integration.
//       The real integration requires:
//       1. Download sherpa-onnx C library (libsherpa-onnx-c-api.dylib)
//       2. Create a bridging header exposing SherpaOnnxOfflineRecognizer
//       3. Load model from ~/.cache/sherpa-onnx/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/
//       4. Call SherpaOnnxCreateOfflineRecognizer, SherpaOnnxDecodeOfflineStream, etc.

import Foundation

// MARK: - SenseVoice tag cleaning regex
// SenseVoice outputs tags like <|zh|><|NEUTRAL|><|Speech|> that must be stripped.
private let senseVoiceTagPattern = try! NSRegularExpression(pattern: #"<\|[^|]*\|>"#)

/// ASR engine wrapping sherpa-onnx SenseVoice.
/// Currently a MOCK implementation that returns dummy text.
///
/// Conforms to SherpaEngineProtocol for ViewModel integration.
final class SherpaEngine: SherpaEngineProtocol {

    // MARK: - Configuration

    /// Path to the sherpa-onnx model directory
    static let modelDir: URL = {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cache
            .appendingPathComponent("sherpa-onnx")
            .appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17")
    }()

    /// HuggingFace model repo for download
    static let modelRepo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"

    // MARK: - State

    private var modelLoaded = false
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
        return modelLoaded
    }

    /// Protocol conformance: the backend name for display.
    var currentBackendName: String {
        return "SenseVoice-ONNX"
    }

    /// Load the ASR model. Call once at startup.
    /// TODO: Replace with real sherpa-onnx model loading:
    ///   1. Check if model.int8.onnx exists at modelDir
    ///   2. If not, download from HuggingFace or GitHub
    ///   3. Create SherpaOnnxOfflineRecognizer with sense_voice config
    func loadModel() {
        lock.lock()
        defer { lock.unlock() }

        onProgress?("Loading SenseVoice-ONNX model...")
        NSLog("[SherpaEngine] Loading model (MOCK)...")

        // TODO: Real implementation:
        // let modelFile = Self.modelDir.appendingPathComponent("model.int8.onnx")
        // if !FileManager.default.fileExists(atPath: modelFile.path) {
        //     downloadModel()
        // }
        // let config = sherpa_onnx_offline_recognizer_config(...)
        // recognizer = SherpaOnnxCreateOfflineRecognizer(&config)

        // Simulate loading delay
        Thread.sleep(forTimeInterval: 0.5)

        modelLoaded = true
        onProgress?("SenseVoice-ONNX ready")
        NSLog("[SherpaEngine] Model loaded (MOCK)")
    }

    /// Transcribe audio data (16kHz, mono, Int16 PCM).
    ///
    /// - Parameters:
    ///   - audioData: Raw PCM audio bytes (Int16, 16kHz, mono)
    ///   - blocking: If false, returns empty string when engine is busy
    /// - Returns: Transcribed text with SenseVoice tags cleaned
    ///
    /// TODO: Replace with real sherpa-onnx transcription:
    ///   1. Convert Int16 PCM to Float32 (divide by 32768.0)
    ///   2. Create offline stream: SherpaOnnxCreateOfflineStream(recognizer)
    ///   3. Accept waveform: SherpaOnnxAcceptWaveformOffline(stream, 16000, samples, count)
    ///   4. Decode: SherpaOnnxDecodeOfflineStream(recognizer, stream)
    ///   5. Get result: SherpaOnnxGetOfflineStreamResult(stream)
    ///   6. Clean SenseVoice tags from result
    /// Protocol conformance: transcribe (blocking).
    func transcribe(audioData: Data) -> String? {
        return transcribeAudio(audioData: audioData, blocking: true)
    }

    /// Transcribe with blocking option.
    func transcribeAudio(audioData: Data, blocking: Bool = true) -> String? {
        guard modelLoaded else { return nil }

        // Minimum audio length check: 0.3 seconds at 16kHz, Int16 = 9600 bytes
        let minBytes = Int(16000 * 0.3) * 2 // 2 bytes per Int16 sample
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
        // TODO: Real implementation — convert to float32 and feed to sherpa-onnx
        // let sampleCount = audioData.count / 2
        // var floatSamples = [Float](repeating: 0, count: sampleCount)
        // audioData.withUnsafeBytes { rawBuf in
        //     let int16Buf = rawBuf.bindMemory(to: Int16.self)
        //     for i in 0..<sampleCount {
        //         floatSamples[i] = Float(int16Buf[i]) / 32768.0
        //     }
        // }
        // ... feed to recognizer ...

        // MOCK: Return dummy text based on audio length
        let durationSeconds = Double(audioData.count) / Double(16000 * 2)
        let mockRaw: String
        if durationSeconds < 1.0 {
            mockRaw = "<|zh|><|NEUTRAL|><|Speech|>你好<|endoftext|>"
        } else if durationSeconds < 3.0 {
            mockRaw = "<|zh|><|NEUTRAL|><|Speech|>这是一段测试语音输入<|endoftext|>"
        } else {
            mockRaw = "<|zh|><|NEUTRAL|><|Speech|>这是一段较长的语音输入，用于测试 VibeKeyboard 的识别功能<|endoftext|>"
        }

        NSLog("[SherpaEngine] Transcribe MOCK: %.1fs audio -> raw: %@", durationSeconds, mockRaw)
        return cleanSenseVoiceTags(mockRaw)
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
