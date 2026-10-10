import Foundation

private func profile(_ enabled: Bool = false, checked: Bool = false) throws -> SpeakerProfile {
    try JSONDecoder().decode(SpeakerProfile.self, from: Data("""
    {"enrolled":true,"validated":\(checked),"enabled":\(enabled),"deferVoiceStart":\(enabled),"message":"Voice profile ready."}
    """.utf8))
}
actor FakeSpeakerAPI: SpeakerProfileAPI {
    var fail = false
    var delayed = false
    var changes = 0
    func configure(fail: Bool = false, delayed: Bool = false) { self.fail = fail; self.delayed = delayed }
    func readSpeakerProfile() async throws -> SpeakerProfile {
        if delayed { try await Task.sleep(for: .milliseconds(80)) }
        if fail { throw HaruError.server(503, "Offline") }
        return try profile()
    }
    func changeSpeakerProfile(_ action: String, audio: Data?) async throws -> SpeakerProfile {
        changes += 1
        if delayed { try await Task.sleep(for: .milliseconds(80)) }
        if fail { throw HaruError.server(503, "Outcome unknown") }
        return try profile(action == "enable", checked: true)
    }
}
@main struct SpeakerProfileTests {
    @MainActor static func main() async throws {
        let api = FakeSpeakerAPI(), setup = SpeakerSetup()
        precondition(setup.needsRefresh && setup.profile == nil)
        try await setup.change("enable", client: api)
        let initialChanges = await api.changes
        precondition(initialChanges == 0, "Write before initial status read")
        try await setup.load(api)
        precondition(!setup.needsRefresh && setup.profile?.enabled == false)
        try await setup.change("enable", client: api)
        precondition(setup.profile?.enabled == true)
        await api.configure(fail: true)
        do { try await setup.change("forget", client: api); fatalError("Failure swallowed") } catch HaruError.server { }
        precondition(setup.needsRefresh && setup.profile?.enabled == true && setup.problem != nil)
        let failedChanges = await api.changes
        try await setup.change("forget", client: api)
        let unchanged = await api.changes
        precondition(unchanged == failedChanges, "Unknown mutation replayed")
        do { try await setup.load(api); fatalError("Read failure swallowed") } catch HaruError.server { }
        precondition(setup.profile == nil && setup.needsRefresh)
        await api.configure(delayed: true)
        let stale = Task { try await setup.load(api) }
        try await Task.sleep(for: .milliseconds(20)); setup.invalidate()
        try await stale.value
        precondition(setup.profile == nil && !setup.busy && setup.needsRefresh, "Late read restored invalidated state")
        await api.configure()
        try await setup.load(api)
        await api.configure(delayed: true)
        let staleWrite = Task { try await setup.change("enable", client: api) }
        try await Task.sleep(for: .milliseconds(20)); setup.invalidate()
        try await staleWrite.value
        precondition(setup.profile == nil && setup.needsRefresh, "Late write confirmed after leaving setup")
        var recording = SpeakerRecording(seconds: 8)
        recording.append(Data(repeating: 17, count: 300_001))
        precondition(recording.complete && recording.pcm.count == 256_000)
        recording.append(Data(repeating: 9, count: 100))
        let wav = recording.wav()
        precondition(wav.count == 256_044 && String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
        precondition(Array(wav[24..<28]) == [128,62,0,0] && Array(wav[34..<36]) == [16,0])
        precondition(wav.suffix(100).allSatisfy { $0 == 17 }, "Overflow changed captured audio")
        let rejected = try JSONDecoder().decode(VoiceDictationReply.self, from: Data(#"{"text":"","speaker":"other","notice":"Give us a moment."}"#.utf8))
        precondition(rejected.text == "" && rejected.notice != nil)
        let accepted = try JSONDecoder().decode(VoiceDictationReply.self, from: Data(#"{"text":"Hello Haru"}"#.utf8))
        precondition(accepted.text == "Hello Haru" && accepted.notice == nil)
        if CommandLine.arguments.count > 1 {
            let client = HaruClient(base: URL(string: CommandLine.arguments[1])!)
            let status = try await client.readSpeakerProfile(); precondition(!status.enabled)
            let uploaded = try await client.changeSpeakerProfile("enroll", audio: wav); precondition(uploaded.enrolled)
            let enabled = try await client.changeSpeakerProfile("enable", audio: nil); precondition(enabled.enabled)
            do { _ = try await client.changeSpeakerProfile("forget", audio: nil); fatalError("401 accepted") } catch HaruError.signedOut { }
        }
        print("Speaker profile: initial-read gate, acknowledged writes, unknown-no-replay, failed/stale reads, stale writes, bounded PCM/WAV, dictation payloads and real HTTP transport passed.")
    }
}
