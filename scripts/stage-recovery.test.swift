import Foundation

@main
struct StageRecoveryTest {
    static func main() {
        var stage = StageRecovery()
        precondition(!stage.ready)
        stage.begin()
        stage.alive(at: 0)
        precondition(stage.ready)
        precondition(stage.terminated(at: 2))
        precondition(!stage.ready && stage.pending)
        stage.begin()
        precondition(!stage.pending && !stage.ready)
        stage.alive(at: 3)
        precondition(stage.terminated(at: 4))
        stage.begin()
        stage.alive(at: 5)
        precondition(!stage.terminated(at: 6), "rapid crashes must stop after two automatic reloads")
        precondition(!stage.ready && !stage.pending)
        stage.begin(manual: true)
        stage.alive(at: 10)
        precondition(stage.terminated(at: 11), "manual reload permits recovery again")
        stage.begin()
        stage.alive(at: 12)
        precondition(stage.terminated(at: 50), "a stable renderer resets the crash burst")
        stage.begin()
        stage.alive(at: 51)
        precondition(stage.terminated(at: 52))
        stage.begin()
        stage.fail()
        precondition(!stage.ready)
        precondition(!stage.terminated(at: 53), "failed loads cannot reset the crash budget")
        print("Stage recovery lifecycle checks passed")
    }
}
