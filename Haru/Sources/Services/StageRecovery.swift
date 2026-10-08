import Foundation

/// A short burst of renderer failures must not become an endless reload loop.
struct StageRecovery {
    private(set) var ready = false
    private(set) var pending = false
    private var failures = 0
    private var aliveSince: TimeInterval?

    mutating func begin(manual: Bool = false) {
        ready = false
        pending = false
        aliveSince = nil
        if manual { failures = 0 }
    }

    mutating func alive(at time: TimeInterval) {
        ready = true
        aliveSince = time
    }

    mutating func fail() {
        ready = false
        aliveSince = nil
    }

    mutating func terminated(at time: TimeInterval) -> Bool {
        if let aliveSince, time - aliveSince >= 30 { failures = 0 }
        fail()
        failures += 1
        pending = failures <= 2
        return pending
    }
}
