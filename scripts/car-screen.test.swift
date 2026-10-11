import Foundation

@main struct CarScreenTests {
    static func main() {
        let all = ["ready", "unavailable", "network", "account", "microphone", "busy", "timeout",
                   "connecting", "listening", "thinking", "speaking"]
        for idle in CarScreen.idle {
            for route in [false, true] {
                let screen = CarScreen(idleState: idle, hasRoute: route)
                assert(screen.identifiers.count <= CarScreen.limit, "CarPlay ignores states after the first five")
                assert(Set(screen.identifiers).count == screen.identifiers.count, "No duplicate states")
                for live in CarScreen.live { assert(screen.carries(live, hasRoute: route), "Every template shows the live states") }
            }
        }

        // A whole call on one template: no rebuilds between connecting, listening, thinking and speaking.
        let first = CarScreen.layout(showing: "ready", hasRoute: false, current: nil)
        assert(first == CarScreen(idleState: "ready", hasRoute: false))
        var current = first
        for state in ["connecting", "listening", "thinking", "speaking", "listening", "ready"] {
            let next = CarScreen.layout(showing: state, hasRoute: false, current: current)
            assert(next == current, "\(state) must not need a new template")
            current = next
        }

        // A failure message needs its own idle state; the live states stay.
        let failed = CarScreen.layout(showing: "timeout", hasRoute: false, current: current)
        assert(failed.idleState == "timeout" && failed != current)
        assert(CarScreen.layout(showing: "connecting", hasRoute: false, current: failed) == failed,
               "Retrying from a failure keeps the template")

        // A prepared route adds Navigate: a new template that keeps the idle message.
        let routed = CarScreen.layout(showing: "speaking", hasRoute: true, current: failed)
        assert(routed.hasRoute && routed.idleState == "timeout")

        // Every state the scene can ask for is reachable.
        for state in all {
            let screen = CarScreen.layout(showing: state, hasRoute: false, current: nil)
            assert(screen.carries(state, hasRoute: false), "\(state) unreachable")
            assert(screen.ordered(first: state).first == state, "A new template opens on the state asked for")
            assert(Set(screen.ordered(first: state)) == Set(screen.identifiers))
        }
        print("car screen: ok")
    }
}
