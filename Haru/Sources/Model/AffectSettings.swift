import Foundation

/// Display data and preferences supplied by Core. The phone does not infer feelings.
struct AffectSettings: Decodable, Sendable {
    struct Control: Decodable, Identifiable, Sendable {
        let key: String
        let label: String
        let description: String
        var id: String { key }
    }
    struct Current: Decodable, Sendable {
        struct Episode: Decodable, Sendable {
            let emotion: String
            let intensity: Double
        }
        let emotion: String
        let disposition: String
        let episodes: [Episode]
        let mood: [String: Double]?
    }
    let enabled: Bool
    let revision: Int
    let preferences: [String: Bool]
    let current: Current
    let controls: [Control]
}

struct AffectSettingsSave: Encodable, Sendable {
    let expectedRevision: Int
    let preferences: [String: Bool]
}
