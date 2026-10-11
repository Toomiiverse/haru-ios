import Foundation

/// Which states the car's voice control template carries.
///
/// CarPlay keeps only the first five states of a voice control template and ignores
/// any after them (CPVoiceControlTemplate init(voiceControlStates:)). Builds up to 169
/// registered twenty-four, so Listening, Thinking and Speaking were never shown: the
/// car said Connecting for a whole conversation (2026-10-11). A template now carries
/// the four live states and the one idle state it needs; a different idle message or
/// the Navigate button means a new template.
struct CarScreen: Equatable {
    static let live = ["connecting", "listening", "thinking", "speaking"]
    static let idle: Set<String> = ["ready", "unavailable", "network", "account", "microphone", "busy", "timeout"]
    static let limit = 5

    let idleState: String
    let hasRoute: Bool

    var identifiers: [String] { [idleState] + Self.live }

    func carries(_ identifier: String, hasRoute: Bool) -> Bool {
        hasRoute == self.hasRoute && identifiers.contains(identifier)
    }

    /// The states in template order, `first` leading: a new template opens on its first state.
    func ordered(first: String) -> [String] {
        identifiers.contains(first) ? [first] + identifiers.filter { $0 != first } : identifiers
    }

    /// The layout that can show `identifier`: the current one when it already can, else a new one.
    static func layout(showing identifier: String, hasRoute: Bool, current: CarScreen?) -> CarScreen {
        if let current, current.carries(identifier, hasRoute: hasRoute) { return current }
        let idleState = idle.contains(identifier) ? identifier : (current?.idleState ?? "ready")
        return CarScreen(idleState: idleState, hasRoute: hasRoute)
    }
}
