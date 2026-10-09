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

        /// A display row per feeling, preserving its strongest reported episode.
        /// Repeated episodes are never added together or written back into Core.
        var displayFeelings: [Episode] {
            Dictionary(grouping: episodes, by: \.emotion)
                .values.compactMap { $0.max { $0.intensity < $1.intensity } }
                .sorted {
                    if $0.intensity == $1.intensity { return $0.emotion < $1.emotion }
                    return $0.intensity > $1.intensity
                }
        }

        var responseDescription: String {
            switch disposition {
            case "engage": return "Ready to talk"
            case "brief": return "Keeping it brief"
            case "defer": return "Needs a little time"
            case "decline": return "Not taking requests right now"
            default: return disposition.capitalized
            }
        }
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

/// Labels for server-supplied dimensions, with no local mood inference.
struct MoodDimension: Identifiable {
    let key: String
    let title: String
    let note: String
    var id: String { key }

    static let all = [
        MoodDimension(key: "pleasantness", title: "Pleasantness", note: "How positive or difficult things feel."),
        MoodDimension(key: "activation", title: "Activation", note: "How stirred up or settled she feels."),
        MoodDimension(key: "tension", title: "Tension", note: "How much strain she is carrying."),
        MoodDimension(key: "energy", title: "Energy", note: "How much she has in her."),
        MoodDimension(key: "sleepiness", title: "Sleepiness", note: "How ready she is for rest."),
    ]
}
