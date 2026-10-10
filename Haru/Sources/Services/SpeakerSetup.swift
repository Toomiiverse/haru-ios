import Foundation
import Observation

protocol SpeakerProfileAPI: Sendable {
    func readSpeakerProfile() async throws -> SpeakerProfile
    func changeSpeakerProfile(_ action: String, audio: Data?) async throws -> SpeakerProfile
}

extension HaruClient: SpeakerProfileAPI {
    func readSpeakerProfile() async throws -> SpeakerProfile {
        try await get("/api/speaker/status")
    }
    func changeSpeakerProfile(_ action: String, audio: Data?) async throws -> SpeakerProfile {
        if let audio {
            return try await upload("/api/speaker/\(action)", data: audio, type: "audio/wav")
        }
        return try await post("/api/speaker/\(action)")
    }
}

/// Shows only acknowledged state. Unknown writes need a read, never a replay.
@MainActor @Observable final class SpeakerSetup {
    private(set) var profile: SpeakerProfile?
    private(set) var busy = false
    private(set) var needsRefresh = true
    private(set) var problem: String?
    private var generation = UUID()
    func invalidate() { generation = UUID(); busy = false; needsRefresh = true; profile = nil }
    func load(_ client: any SpeakerProfileAPI) async throws {
        guard !busy else { return }
        let ticket = generation
        busy = true
        defer { if generation == ticket { busy = false } }
        do {
            let result = try await client.readSpeakerProfile()
            guard generation == ticket, !Task.isCancelled else { return }
            profile = result; needsRefresh = false; problem = nil
        } catch {
            guard generation == ticket else { return }
            profile = nil; needsRefresh = true; problem = error.localizedDescription
            throw error
        }
    }
    func change(_ action: String, audio: Data? = nil, client: any SpeakerProfileAPI) async throws {
        guard !busy, !needsRefresh else { return }
        let ticket = generation
        busy = true
        defer { if generation == ticket { busy = false } }
        do {
            let result = try await client.changeSpeakerProfile(action, audio: audio)
            guard generation == ticket, !Task.isCancelled else { return }
            profile = result; needsRefresh = false
            if let check = result.check, check.speaker != "owner" {
                problem = "That recording did not verify your voice. Try a fresh recording in a quiet place."
            } else { problem = nil }
        } catch {
            guard generation == ticket else { return }
            needsRefresh = true
            problem = "Could not confirm the change. Refresh before trying again. \(error.localizedDescription)"
            throw error
        }
    }
}
