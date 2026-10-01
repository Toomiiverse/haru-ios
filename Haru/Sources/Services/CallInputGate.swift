/// Local transmission gate. Server acknowledgements never reopen a released hold.
struct CallInputGate {
    private(set) var manual = false
    private(set) var held = false
    private(set) var acknowledged = true
    var sendsAudio: Bool { acknowledged && (!manual || held) }

    mutating func select(_ enabled: Bool) {
        manual = enabled
        held = false
        acknowledged = false
    }
    mutating func acknowledge(_ enabled: Bool) {
        guard enabled == manual else { return }
        acknowledged = true
        held = false
    }
    mutating func hold(_ active: Bool) -> Bool {
        guard manual, acknowledged, active != held else { return false }
        held = active
        return true
    }
    mutating func serverGate(_ active: Bool) {
        if !active { held = false }
    }
}
