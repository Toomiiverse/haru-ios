import AVFoundation
import Foundation
import Observation
import Speech

/// One spoken turn, transcribed on this iPhone and sent through the normal local conversation.
@MainActor @Observable final class LocalSpeechInput {
    private(set) var listening = false
    private(set) var transcript = ""
    var problem: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var identity: UUID?
    private var tapped = false
    private var received: ((String) -> Void)?

    func start(received: @escaping (String) -> Void) async {
        guard identity == nil else { return }
        let id = UUID(); identity = id; problem = nil
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard identity == id else { return }
        guard permission == .authorized, await Audio.allowed() else {
            identity = nil; problem = "Allow Microphone and Speech Recognition for Haru in iPhone Settings."; return
        }
        guard identity == id else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.supportsOnDeviceRecognition else {
            identity = nil; problem = "On-device speech recognition is unavailable for this language. You can still type to Haru."; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            self.request = request; self.received = received; transcript = ""
            let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw LocalChatError.message("No microphone input is available.") }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapped = true
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let errorText = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.identity == id else { return }
                    if let text, !text.isEmpty {
                        self.transcript = text
                        self.silence?.cancel()
                        self.silence = Task { [weak self] in
                            do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
                            guard self?.identity == id else { return }
                            self?.stop(submit: true)
                        }
                    }
                    if final { self.stop(submit: true) }
                    else if let errorText { self.problem = errorText; self.stop(submit: false) }
                }
            }
            engine.prepare(); try engine.start(); listening = true
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard self?.identity == id else { return }
                self?.stop(submit: true)
            }
        } catch { problem = error.localizedDescription; stop(submit: false) }
    }

    func stop(submit: Bool = false) {
        let text = transcript, callback = received
        identity = nil; received = nil; listening = false
        silence?.cancel(); deadline?.cancel(); silence = nil; deadline = nil
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); recognition?.cancel(); request = nil; recognition = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if submit, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { callback?(text) }
    }
}
