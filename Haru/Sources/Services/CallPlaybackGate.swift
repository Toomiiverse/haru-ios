import Foundation

/// Transport cancellation and queued callback identity, not conversation state.
struct CallPlaybackGate {
    struct Token: Equatable, Sendable { let callID: UUID; let generation: Int }
    private let callID = UUID()
    private var generation = 0
    private var closed = false
    private(set) var pendingRequest: String?
    private(set) var audioBlocked = false
    var token: Token { Token(callID: callID, generation: generation) }
    func accepts(_ token: Token) -> Bool { token == self.token }

    mutating func interrupt(requestID: String, supported: Bool) {
        guard !closed else { return }
        generation += 1
        audioBlocked = true
        pendingRequest = supported ? requestID : nil
    }
    mutating func acknowledge(_ requestID: String?) -> Bool {
        guard !closed else { return false }
        if let pendingRequest {
            guard requestID == pendingRequest else { return false }
        } else {
            guard requestID == nil else { return false }
            // A server-originated barge-in invalidates already queued callbacks.
            generation += 1
        }
        pendingRequest = nil
        audioBlocked = false
        return true
    }
    mutating func newUserTurn() {
        // An older server has no interruption receipt. Only a new actual user
        // turn may release its stopped audio; an audio_start alone cannot.
        if !closed && pendingRequest == nil { audioBlocked = false }
    }
    mutating func close() {
        closed = true
        generation += 1
        pendingRequest = nil
        audioBlocked = true
    }
}
