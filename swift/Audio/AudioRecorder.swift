// AudioRecorder.swift
// VibeKeyboard — Microphone audio capture using AVAudioEngine
//
// Captures 16kHz mono Int16 PCM audio, matching the format expected by sherpa-onnx SenseVoice.

import Foundation
import AVFoundation

/// Audio recorder that captures microphone input at 16kHz mono Int16 PCM.
///
/// Usage:
///   let recorder = AudioRecorder()
///   recorder.onAudioChunk = { data in /* process PCM chunk */ }
///   recorder.start()
///   // ... later ...
///   recorder.stop()
///   let allAudio = recorder.audioBuffer
///
/// Conforms to AudioRecorderProtocol for ViewModel integration.
final class AudioRecorder: AudioRecorderProtocol {

    // MARK: - Constants

    static let sampleRate: Double = 16000
    static let channels: AVAudioChannelCount = 1
    /// Buffer size in frames per callback (~100ms at 16kHz)
    static let bufferFrameSize: AVAudioFrameCount = 1600

    // MARK: - Properties

    /// Whether recording is currently active
    private(set) var isRecording = false

    /// Callback invoked with each audio chunk (Int16 PCM bytes)
    var onAudioChunk: ((Data) -> Void)?

    /// Accumulated audio data since start()
    private(set) var audioBuffer = Data()

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    // MARK: - Public API

    /// Start recording from the default microphone.
    ///
    /// Audio is captured at 16kHz mono Int16 format.
    /// Each chunk is delivered via `onAudioChunk` and also accumulated in `audioBuffer`.
    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRecording else {
            NSLog("[AudioRecorder] Already recording, ignoring start()")
            return
        }

        audioBuffer = Data()

        let inputNode = engine.inputNode

        // The hardware format — we'll convert from this
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        NSLog("[AudioRecorder] Hardware format: %@", hardwareFormat.description)

        // Target format: 16kHz mono Float32 (AVAudioEngine operates in float)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        ) else {
            NSLog("[AudioRecorder] ERROR: Cannot create target audio format")
            return
        }

        // Install a tap on the input node
        // AVAudioEngine will resample from hardware format to our target format
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.bufferFrameSize,
            format: targetFormat
        ) { [weak self] (buffer, time) in
            self?.processAudioBuffer(buffer)
        }

        do {
            try engine.start()
            isRecording = true
            NSLog("[AudioRecorder] Recording started (16kHz mono)")
        } catch {
            NSLog("[AudioRecorder] ERROR: Failed to start engine: %@", error.localizedDescription)
            inputNode.removeTap(onBus: 0)
        }
    }

    /// Stop recording and release audio resources.
    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRecording else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        NSLog("[AudioRecorder] Recording stopped, buffer size: %d bytes", audioBuffer.count)
    }

    /// Get the accumulated audio buffer and clear it.
    func consumeBuffer() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let data = audioBuffer
        audioBuffer = Data()
        return data
    }

    /// Get a chunk of audio data (protocol conformance).
    /// Returns accumulated audio buffer or nil if empty.
    func getChunk(timeout: TimeInterval) -> Data? {
        // Wait up to `timeout` for data to appear
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let data = audioBuffer
            lock.unlock()
            if !data.isEmpty {
                return data
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        lock.lock()
        let data = audioBuffer
        lock.unlock()
        return data.isEmpty ? nil : data
    }

    // MARK: - Private

    /// Convert Float32 audio buffer to Int16 PCM and deliver
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Convert Float32 [-1.0, 1.0] to Int16 [-32768, 32767]
        var int16Data = Data(count: frameCount * MemoryLayout<Int16>.size)
        int16Data.withUnsafeMutableBytes { rawBuf in
            let int16Buf = rawBuf.bindMemory(to: Int16.self)
            let floatPtr = floatData[0] // channel 0
            for i in 0..<frameCount {
                let sample = floatPtr[i]
                // Clamp to [-1.0, 1.0] then scale
                let clamped = max(-1.0, min(1.0, sample))
                int16Buf[i] = Int16(clamped * 32767.0)
            }
        }

        // Accumulate
        lock.lock()
        audioBuffer.append(int16Data)
        lock.unlock()

        // Deliver chunk via callback
        onAudioChunk?(int16Data)
    }

    // MARK: - Microphone Permission

    /// Request microphone access. Returns true if granted.
    static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}
