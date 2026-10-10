import SwiftUI

struct SpeakerProfileView: View {
    @Environment(Session.self) private var session
    @Environment(ChatStore.self) private var chat
    @Environment(\.scenePhase) private var phase
    @State private var setup = SpeakerSetup()
    @State private var recorder = SpeakerRecorder()
    @State private var operation: Task<Void, Never>?
    @State private var working = false
    @State private var problem: String?
    @State private var confirmForget = false
    @State private var confirmReplace = false
    @State private var recordingSeconds = 20

    private var audioInUse: Bool {
        chat.audio.listening || chat.audio.speaking || chat.callState != .off || chat.busy || chat.enrolling != nil
    }
    private var locked: Bool { working || setup.busy || recorder.recording }

    var body: some View {
        Form {
            Section {
                Text(setup.profile?.message ?? "Load your voice profile to get started.")
                if let profile = setup.profile {
                    LabeledContent("Conversation filtering", value: profile.enabled ? "On" : "Off")
                    LabeledContent("Voice check", value: profile.validated ? "Verified" : "Needed")
                }
            } header: { Text("My voice") } footer: {
                Text("Shared with Haru on the web. When enabled, your recognized voice can enter the conversation; other or uncertain voices are ignored or get a brief interruption notice.")
            }
            if audioInUse {
                Section { Text("End your call, stop standby and wait for playback to finish before changing your voice profile.") }
            }
            Section {
                if recorder.recording {
                    ProgressView(value: Double(recorder.elapsed), total: Double(recordingSeconds))
                    Text("Recording: \(recorder.elapsed) of \(recordingSeconds) seconds")
                        .monospacedDigit()
                    ProgressView(value: recorder.level).accessibilityLabel("Microphone level")
                    Button("Cancel recording", role: .cancel) { cancel() }
                } else {
                    Button(setup.profile?.enrolled == true ? "Record my voice again · 20 seconds" : "Record my voice · 20 seconds") {
                        if setup.profile?.enrolled == true { confirmReplace = true } else { record("enroll", seconds: 20) }
                    }.disabled(locked || audioInUse || setup.needsRefresh)
                    Button("Check with a fresh recording · 8 seconds") { record("validate", seconds: 8) }
                        .disabled(locked || audioInUse || setup.needsRefresh || setup.profile?.enrolled != true)
                }
            } footer: {
                Text("Speak naturally for the whole recording. For the check, say something different. Core processes the recording on your Haru server and keeps a voice profile, not the raw enrollment audio.")
            }
            Section {
                if setup.profile?.enabled == true {
                    Button("Turn filtering off") { change("disable") }
                        .disabled(locked || audioInUse || setup.needsRefresh)
                } else {
                    Button("Enable only my voice") { change("enable") }
                        .disabled(locked || audioInUse || setup.needsRefresh || setup.profile?.validated != true)
                }
                Button("Forget conversation voice profile", role: .destructive) { confirmForget = true }
                    .disabled(locked || audioInUse || setup.needsRefresh || setup.profile?.enrolled != true)
            } footer: {
                Text("Start a new call after a change. Short, noisy or overlapping speech may be uncertain. The separate standby wake-word profile is managed under More → Talking.")
            }
            if let message = problem ?? setup.problem { Section("Needs attention") { Text(message) } }
            Section {
                Button(setup.needsRefresh ? "Refresh voice status" : "Refresh") { refresh() }.disabled(locked)
                if working && !recorder.recording { ProgressView("Checking with Haru…") }
            }
        }
        .navigationTitle("My voice")
        .task(id: session.baseURLString) { cancel(); refresh() }
        .onDisappear { cancel() }
        .onChange(of: phase) { _, next in if next != .active { cancel() } }
        .onChange(of: audioInUse) { _, used in if used && working { cancel() } }
        .confirmationDialog("Replace your conversation voice profile? Filtering will turn off until you check and enable the new profile.", isPresented: $confirmReplace) {
            Button("Record a new profile", role: .destructive) { record("enroll", seconds: 20) }
        }
        .confirmationDialog("Forget the shared conversation voice profile?", isPresented: $confirmForget) {
            Button("Forget profile", role: .destructive) { change("forget") }
        }
    }
    private func cancel() {
        operation?.cancel(); operation = nil; recorder.cancel(); setup.invalidate(); working = false
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !locked else { return }
        problem = nil; working = true
        operation = Task { @MainActor in
            defer { if !Task.isCancelled { working = false } }
            do { try await work() }
            catch is CancellationError { }
            catch HaruError.signedOut { session.signedIn = false }
            catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
    }
    private func refresh() { run { try await setup.load(session.client) } }
    private func change(_ action: String) {
        guard !audioInUse else { return }
        run { try await setup.change(action, client: session.client) }
    }
    private func record(_ action: String, seconds: Int) {
        guard !audioInUse else { return }
        recordingSeconds = seconds
        let client = session.client
        run {
            let wav = try await recorder.record(seconds: seconds)
            try Task.checkCancellation()
            try await setup.change(action, audio: wav, client: client)
        }
    }
}
