import Combine
import Foundation
import AppKit

// MARK: - Application State

enum AppState: String {
    case idle
    case recording
    case processing
    case loading
    case error
}

// MARK: - ViewModel

/// Central coordinator for VibeKeyboard.
/// Manages recording workflow, overlay display, and component integration.
///
/// Workflow:
///   Double-tap Option -> startRecording() -> show overlay
///   Streaming recognition every 0.2s -> update overlay text
///   Enter -> stopAndPaste() -> format, polish, paste, hide overlay
///   ESC -> cancelRecording() -> hide overlay
final class VibeKeyboardViewModel: ObservableObject {

    // MARK: - Published State

    @Published var appState: AppState = .loading
    @Published var isRecording: Bool = false
    @Published var isModelLoaded: Bool = false
    @Published var statusText: String = "Loading..."
    @Published var currentText: String = ""
    @Published var overlayVisible: Bool = false
    @Published var backendName: String = "SenseVoice-ONNX"
    @Published var hotwordCount: Int = 0

    // MARK: - Components (protocol-typed for testability)

    private var audioRecorder: AudioRecorderProtocol
    private var sherpaEngine: SherpaEngineProtocol
    private var textInserter: TextInserterProtocol
    private var hotkeyListener: HotkeyListenerProtocol
    private var formatter: TextFormatterProtocol
    private var polisher: TextPolisherProtocol
    private var configManager: ConfigManager { ConfigManager.shared }

    // MARK: - Internal State

    private let stopLock = NSLock()
    private var audioBuffer = Data()
    private var hasVoice = false
    private var streamBusy = false
    private var lastStreamText = ""
    private var hideTimer: Timer?
    private var streamTimer: Timer?

    /// The app that was frontmost when recording started — paste goes here.
    private var targetApp: NSRunningApplication?

    /// The overlay window instance (AppKit, not SwiftUI).
    private lazy var overlay: OverlayWindow = {
        let fontSize = CGFloat(configManager.overlayFontSize)
        return OverlayWindow(fontSize: fontSize)
    }()

    // MARK: - Init

    init() {
        // Initialize real backend components
        let config = ConfigManager.shared
        audioRecorder = AudioRecorder()
        sherpaEngine = SherpaEngine()
        textInserter = TextInserter()
        hotkeyListener = HotkeyListener()
        formatter = TextFormatter(config: config.formattingConfig)
        polisher = TextPolisher()

        // Load config
        hotwordCount = config.hotwords.count

        // Wire audio chunk callback
        if let recorder = audioRecorder as? AudioRecorder {
            recorder.onAudioChunk = { [weak self] chunk in
                guard let self = self else { return }
                self.audioBuffer.append(chunk)
                // Once we have enough audio, mark that voice is present
                if self.audioBuffer.count > 16000 * 2 {  // > 1 second
                    self.hasVoice = true
                }
            }
        }

        setupHotkeyListener()

        // Request accessibility permission for Cmd+V simulation
        TextInserter.requestAccessibilityIfNeeded()

        // Load ASR model in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadModel()
        }
    }

    // MARK: - Hotkey Setup

    private func setupHotkeyListener() {
        hotkeyListener.onPress = { [weak self] in
            DispatchQueue.main.async {
                self?.startRecording()
            }
        }
        hotkeyListener.onCancel = { [weak self] in
            DispatchQueue.main.async {
                self?.cancelRecording()
            }
        }
        hotkeyListener.onConfirm = { [weak self] in
            DispatchQueue.main.async {
                self?.stopAndPaste()
            }
        }
        hotkeyListener.start()
    }

    // MARK: - Model Loading

    private func loadModel() {
        DispatchQueue.main.async { [weak self] in
            self?.appState = .loading
            self?.statusText = "Loading model..."
        }

        sherpaEngine.loadModel()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isModelLoaded = true
            self.appState = .idle
            self.statusText = "Idle (double-tap Option to record)"
            self.backendName = self.sherpaEngine.currentBackendName
        }
    }

    // MARK: - Recording Workflow

    /// Start recording. Called by double-tap Option hotkey.
    func startRecording() {
        // Double-tap Option while recording = confirm & paste (same as Enter)
        if isRecording {
            stopAndPaste()
            return
        }
        guard isModelLoaded else { return }

        cancelHideTimer()

        // Save the frontmost app so we can paste back to it later
        targetApp = NSWorkspace.shared.frontmostApplication

        isRecording = true
        appState = .recording
        statusText = "Recording..."
        audioBuffer = Data()
        hasVoice = false
        lastStreamText = ""
        currentText = ""

        audioRecorder.start()
        overlay.show(text: "", showIndicator: true)
        overlayVisible = true

        // Start streaming recognition timer (every 0.2s)
        startStreamTimer()

        FileLogger.log("[VibeKeyboard] Recording started, target=\(targetApp?.localizedName ?? "nil")")
    }

    /// Stop recording, format/polish the text, paste it, and hide overlay.
    /// Called by Enter key.
    ///
    /// IMPORTANT: We hide the overlay BEFORE pasting so that our floating window
    /// does not interfere with target app activation. The overlay uses
    /// `hidesOnDeactivate = false` and `.transient` collection behavior,
    /// so hiding it should not steal focus. We order it out first, then
    /// trigger the paste on a background queue.
    func stopAndPaste() {
        stopLock.lock()
        guard isRecording else {
            stopLock.unlock()
            return
        }
        isRecording = false
        stopLock.unlock()

        stopStreamTimer()
        audioRecorder.stop()

        let text = lastStreamText

        // Hide overlay immediately so it doesn't compete for activation.
        // Use orderOut (instant) instead of animated hide to avoid timing issues.
        overlay.hideInstant()
        overlayVisible = false
        appState = .idle
        statusText = "Idle (double-tap Option to record)"

        let target = targetApp
        FileLogger.log("[VibeKeyboard] Recording stopped. text=\(text.isEmpty ? "(empty)" : String(text.prefix(40))), target=\(target?.localizedName ?? "nil")")

        if !text.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.quickPaste(text, target: target)
            }
        } else {
            let audioData = audioBuffer
            if !audioData.isEmpty {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.fullTranscribe(audioData, target: target)
                }
            } else {
                FileLogger.log("[VibeKeyboard] No text and no audio data, nothing to paste")
            }
        }
    }

    /// Cancel recording without pasting. Called by ESC key.
    func cancelRecording() {
        stopLock.lock()
        guard isRecording else {
            stopLock.unlock()
            return
        }
        isRecording = false
        stopLock.unlock()

        stopStreamTimer()
        audioRecorder.stop()
        audioBuffer = Data()

        overlay.hide()
        overlayVisible = false
        appState = .idle
        statusText = "Idle (double-tap Option to record)"
        currentText = ""

        NSLog("[VibeKeyboard] Recording cancelled (ESC)")
    }

    // MARK: - Streaming Recognition

    private func startStreamTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.streamTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.performStreamRecognition()
            }
        }
    }

    private func stopStreamTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.streamTimer?.invalidate()
            self?.streamTimer = nil
        }
    }

    private func performStreamRecognition() {
        guard isRecording, hasVoice, !streamBusy else { return }

        let snapshot = audioBuffer
        guard !snapshot.isEmpty else { return }

        streamBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { self.streamBusy = false }

            guard let text = self.sherpaEngine.transcribe(audioData: snapshot), !text.isEmpty else {
                return
            }

            guard self.isRecording else { return }
            self.lastStreamText = text

            DispatchQueue.main.async {
                self.currentText = text
                self.overlay.updateText(text)
            }
        }
    }

    // MARK: - Transcription & Pasting

    private func quickPaste(_ text: String, target: NSRunningApplication?) {
        let formatted = formatter.format(text)
        let polished = polisher.polish(formatted)

        FileLogger.log("[VibeKeyboard] Quick paste: \(polished)")
        textInserter.insertText(polished, activating: target)
    }

    private func fullTranscribe(_ audioData: Data, target: NSRunningApplication? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.appState = .processing
            self?.statusText = "Transcribing..."
        }

        guard let text = sherpaEngine.transcribe(audioData: audioData), !text.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.overlay.updateText("(No speech detected)")
                self?.scheduleHide(delay: 1.5)
                self?.appState = .idle
                self?.statusText = "Idle (double-tap Option to record)"
            }
            return
        }

        let formatted = formatter.format(text)
        let polished = polisher.polish(formatted)

        DispatchQueue.main.async { [weak self] in
            self?.overlay.updateText(polished)
            self?.scheduleHide(delay: 3.0)
            self?.appState = .idle
            self?.statusText = "Idle (double-tap Option to record)"
        }

        textInserter.insertText(polished, activating: target)
    }

    // MARK: - Timer Helpers

    private func scheduleHide(delay: TimeInterval) {
        cancelHideTimer()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.overlay.hide()
            DispatchQueue.main.async {
                self?.overlayVisible = false
            }
        }
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    // MARK: - Cleanup

    func cleanup() {
        hotkeyListener.stop()
        cancelHideTimer()
        stopStreamTimer()
        if isRecording {
            audioRecorder.stop()
        }
        overlay.hide()
        NSLog("[VibeKeyboard] Cleanup complete")
    }
}

// MARK: - Component Protocols
// These define the interface contract for each module.
// The actual implementations live in their respective directories.

protocol AudioRecorderProtocol: AnyObject {
    var isRecording: Bool { get }
    func start()
    func stop()
    func getChunk(timeout: TimeInterval) -> Data?
}

protocol SherpaEngineProtocol: AnyObject {
    var isReady: Bool { get }
    var currentBackendName: String { get }
    func loadModel()
    func transcribe(audioData: Data) -> String?
}

protocol TextInserterProtocol: AnyObject {
    func insertText(_ text: String)
    func insertText(_ text: String, activating app: NSRunningApplication?)
}

protocol HotkeyListenerProtocol: AnyObject {
    var onPress: (() -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    var onConfirm: (() -> Void)? { get set }
    func start()
    func stop()
}

protocol TextFormatterProtocol: AnyObject {
    func format(_ text: String) -> String
}

protocol TextPolisherProtocol: AnyObject {
    func polish(_ text: String) -> String
}
