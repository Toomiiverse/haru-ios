import Foundation
import Observation

@MainActor @Observable final class SpeakerRecorder {
    private(set) var recording = false
    private(set) var elapsed = 0
    private(set) var level = 0.0
    private var audio: Audio?
    private var capture: SpeakerRecording?
    private var generation = UUID()

    func record(seconds: Int) async throws -> Data {
        cancel()
        let ticket = generation
        guard await Audio.allowed() else { throw HaruError.server(403, "Allow microphone access for Haru in Settings.") }
        try Task.checkCancellation()
        guard ticket == generation else { throw CancellationError() }
        let ear = Audio()
        audio = ear
        capture = SpeakerRecording(seconds: seconds)
        elapsed = 0; level = 0; recording = true
        ear.onFrames = { [weak self] frame in
            guard let self, self.generation == ticket, self.recording else { return }
            self.capture?.append(frame)
            self.elapsed = self.capture?.elapsed ?? 0
            self.level = ear.level
        }
        ear.onInterruption = { [weak self] began, _ in if began { self?.cancel() } }
        defer { if generation == ticket { cancel() } }
        ear.stream(true)
        do { try ear.listen(true) } catch { ear.releaseSession(); throw error }
        let deadline = Date().addingTimeInterval(Double(seconds + 10))
        while capture?.complete != true {
            try await Task.sleep(for: .milliseconds(100))
            guard generation == ticket else { throw CancellationError() }
            guard Date() < deadline else { throw HaruError.server(408, "The microphone stopped sending audio. Try recording again.") }
        }
        try Task.checkCancellation()
        guard let capture, generation == ticket else { throw CancellationError() }
        return capture.wav()
    }
    func cancel() {
        generation = UUID()
        audio?.onFrames = nil; audio?.onInterruption = nil
        audio?.stream(false); try? audio?.listen(false); audio?.releaseSession()
        audio = nil; capture = nil; recording = false; level = 0
    }
}
