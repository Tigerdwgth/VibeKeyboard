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
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    // MARK: - Public API

    /// Start recording from the default microphone.
    ///
    /// Audio is captured at the hardware's native format, then converted to
    /// 16kHz mono Int16 in the tap callback using AVAudioConverter.
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
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        NSLog("[AudioRecorder] Hardware format: %@", nativeFormat.description)

        // Target format: 16kHz mono Float32 (we convert to Int16 after)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        ) else {
            NSLog("[AudioRecorder] ERROR: Cannot create target audio format")
            return
        }
        self.targetFormat = target

        // Create converter from native hardware format to 16kHz mono Float32
        guard let conv = AVAudioConverter(from: nativeFormat, to: target) else {
            NSLog("[AudioRecorder] ERROR: Cannot create AVAudioConverter from %@ to %@",
                  nativeFormat.description, target.description)
            return
        }
        self.converter = conv
        NSLog("[AudioRecorder] Converter ready: %@ -> %@", nativeFormat.description, target.description)

        // Install a tap with nil format = use the hardware's native format.
        // This avoids the SIGABRT in AVAudioIONodeImpl::SetOutputFormat that
        // occurs when requesting a format the input node cannot provide directly.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nil
        ) { [weak self] (buffer, time) in
            self?.convertAndProcess(buffer: buffer)
        }

        do {
            try engine.start()
            isRecording = true
            NSLog("[AudioRecorder] Recording started (native -> 16kHz mono conversion)")
        } catch {
            NSLog("[AudioRecorder] ERROR: Failed to start engine: %@", error.localizedDescription)
            inputNode.removeTap(onBus: 0)
            self.converter = nil
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
        converter = nil
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

    /// Convert audio buffer from native hardware format to 16kHz mono, then to Int16 PCM.
    private func convertAndProcess(buffer: AVAudioPCMBuffer) {
        guard let converter = self.converter,
              let targetFormat = self.targetFormat else { return }

        // Calculate how many output frames we need
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        // Use AVAudioConverter to resample + downmix
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let error = error {
                NSLog("[AudioRecorder] Conversion error: %@", error.localizedDescription)
            }
            return
        }

        guard outputBuffer.frameLength > 0 else { return }

        // Convert Float32 to Int16 PCM
        processFloat32Buffer(outputBuffer)
    }

    /// Convert Float32 audio buffer to Int16 PCM and deliver
    private func processFloat32Buffer(_ buffer: AVAudioPCMBuffer) {
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
