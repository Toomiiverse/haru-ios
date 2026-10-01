@main struct CallInputGateTests {
    static func main() {
        var gate = CallInputGate()
        precondition(gate.sendsAudio)
        gate.select(true)
        precondition(!gate.sendsAudio && !gate.hold(true))
        gate.acknowledge(true)
        precondition(!gate.sendsAudio && gate.hold(true) && gate.sendsAudio)
        precondition(gate.hold(false) && !gate.sendsAudio)
        gate.serverGate(true) // Delayed press acknowledgement after release.
        precondition(!gate.sendsAudio)
        precondition(gate.hold(true))
        gate.serverGate(false) // Server's maximum hold limit.
        precondition(!gate.sendsAudio)
        gate.select(false)
        precondition(!gate.sendsAudio)
        gate.acknowledge(true) // Stale mode acknowledgement.
        precondition(!gate.sendsAudio)
        gate.acknowledge(false)
        precondition(gate.sendsAudio)
        print("Call input gate checks passed")
    }
}
