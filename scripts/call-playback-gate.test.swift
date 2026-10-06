import Foundation
@main struct CallPlaybackGateChecks {
    static func main() {
        var gate = CallPlaybackGate()
        let initial = gate.token
        precondition(gate.accepts(initial) && !gate.audioBlocked)
        gate.interrupt(requestID: "first", supported: true)
        precondition(!gate.accepts(initial) && gate.audioBlocked)
        let first = gate.token
        precondition(!gate.acknowledge(nil) && !gate.acknowledge("wrong") && gate.audioBlocked)
        gate.newUserTurn()
        precondition(gate.audioBlocked, "New audio must wait for the receipt on a capable server")
        gate.interrupt(requestID: "second", supported: true)
        precondition(!gate.accepts(first) && !gate.acknowledge("first") && gate.audioBlocked)
        precondition(gate.acknowledge("second") && !gate.audioBlocked)
        let resumed = gate.token
        precondition(!gate.acknowledge("second") && gate.accepts(resumed), "A duplicate receipt cannot interrupt a new answer")
        precondition(gate.acknowledge(nil) && !gate.accepts(resumed), "Server barge-in invalidates queued playback")
        let beforeClose = gate.token
        gate.close()
        precondition(!gate.accepts(beforeClose) && gate.audioBlocked)
        precondition(!gate.acknowledge(nil) && !gate.acknowledge("second"))
        gate.newUserTurn()
        precondition(gate.audioBlocked)
        let anotherCall = CallPlaybackGate()
        precondition(!anotherCall.accepts(gate.token), "Old call callbacks cannot reach a new socket")
        var legacy = CallPlaybackGate()
        legacy.interrupt(requestID: "no-capability", supported: false)
        precondition(legacy.audioBlocked)
        legacy.newUserTurn()
        precondition(!legacy.audioBlocked, "A real new turn releases legacy local suppression")
        // Repeated taps and delayed receipts across a larger sequence.
        var repeated = CallPlaybackGate()
        for index in 0..<64 {
            let previous = repeated.token
            repeated.interrupt(requestID: "tap-\(index)", supported: true)
            precondition(!repeated.accepts(previous) && repeated.audioBlocked)
            precondition(!repeated.acknowledge("tap-\(index-1)"))
            precondition(repeated.acknowledge("tap-\(index)") && !repeated.audioBlocked)
        }
        print("Call playback transport checks passed: cancellation, queued callbacks, matching/stale/repeated receipts, close, old call and legacy release; 64 repeated taps.")
    }
}
