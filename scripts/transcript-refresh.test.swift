import Foundation

@main
struct TranscriptRefreshTests {
    @MainActor static func main() async {
        let gate = TranscriptRefreshGate()
        var visible = "Traffic"
        let staleTraffic = gate.begin()
        visible = "Weather"
        gate.invalidate() // A streamed sentence or completed reply changed the screen.
        if gate.accepts(staleTraffic) { visible = "Traffic" }
        precondition(visible == "Weather", "Late traffic history overwrote weather")

        let older = gate.begin()
        let newer = gate.begin()
        precondition(gate.accepts(newer))
        visible = "Newer weather"
        if gate.accepts(older) { visible = "Older weather" }
        precondition(visible == "Newer weather", "Out-of-order refresh won")
        precondition(!gate.isLatest(older) && gate.isLatest(newer), "Old completion cleared loading")

        for _ in ["send started", "call started", "call ended", "entry edited"] {
            let pending = gate.begin()
            gate.invalidate()
            precondition(!gate.accepts(pending), "Changed activity accepted stale history")
            precondition(gate.isLatest(pending), "Rejected refresh left loading stuck")
        }
        let current = gate.begin()
        precondition(gate.accepts(current), "Quiet current history could not load")

        // Assert the tested fence surrounds the actual network await and mutation.
        let source = try! String(contentsOfFile: "Haru/Sources/State/ChatStore.swift", encoding: .utf8)
        precondition(source.contains("var entries: [Entry] = [] { didSet { historyRefresh.invalidate() } }"))
        precondition(source.contains("guard isCurrent() else { return }"))
        precondition(source.contains("self.client.base == client.base && call == nil"))
        precondition(source.contains("await load(completedReply: final)"))
        precondition(source.contains("self.callGeneration == generation"))
        precondition(source.components(separatedBy: "say(line.text, emotion: line.emotion, seed: speechSeed)").count == 3)
        print("Transcript: stale traffic, reordered refresh, active turn/call changes, loading cleanup and current refresh passed; production wiring checked.")
    }
}
