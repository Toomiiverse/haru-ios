import Foundation

// The shapes the server's web routes hand out (electron/webserver.ts, WebDeps).
// Numbers are decoded as Double wherever the source says `number`, so a value
// that turns out fractional never breaks a whole screen.

/// One line of the day, as GET /api/chat returns it.
struct ServerMessage: Decodable {
    let id: String?
    let role: String
    let content: String
    let at: String?
    let reaction: String?
    let note: String?
    /// A string tag on the desktop; anything present and truthy is an aside.
    let aside: Bool
    /// What rode the message: a picture shows in the bubble, anything else by name.
    let attachments: [Attached]
    /// The line of hers a message of his answers, as the server quoted it back.
    let replyTo: ReplyTo?

    struct ReplyTo: Decodable {
        let id: String
        let excerpt: String
    }

    struct Attached: Decodable {
        let name: String
        let kind: String
        let saved: String
        /// Hers rather than his: drawn behind a tap. "private" is a keyword in
        /// Swift, so the name here is ours and the key is the server's.
        let isPrivate: Bool

        private enum CodingKeys: String, CodingKey { case name, kind, saved, isPrivate = "private" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
            saved = (try? c.decodeIfPresent(String.self, forKey: .saved)) ?? ""
            isPrivate = (try? c.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? false
        }
    }

    private enum CodingKeys: String, CodingKey { case id, role, content, at, reaction, note, aside, attachments, replyTo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "system"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        at = try c.decodeIfPresent(String.self, forKey: .at)
        reaction = try c.decodeIfPresent(String.self, forKey: .reaction)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        attachments = (try? c.decodeIfPresent([Attached].self, forKey: .attachments)) ?? []
        // Lenient on purpose: a reference the phone cannot read loses the quote,
        // never the whole day.
        replyTo = try? c.decodeIfPresent(ReplyTo.self, forKey: .replyTo)
        if let tag = try c.decodeIfPresent(JSONValue.self, forKey: .aside) {
            switch tag {
            case .null: aside = false
            case .bool(let b): aside = b
            case .string(let s): aside = !s.isEmpty
            default: aside = true
            }
        } else {
            aside = false
        }
    }
}

struct ChatPage: Decodable { let messages: [ServerMessage] }

/// One `data:` line of /api/chat/stream or /api/chat/retry.
struct StreamEvent: Decodable {
    let text: String?
    let sentence: String?
    let emotion: String?
    let done: Bool?
    let reply: String?
    let ignored: Bool?
    let error: String?
}

struct Expression: Decodable { let emotion: String?; let expression: String? }
struct WakeWord: Decodable { let line: String?; let emotion: String? }
struct Nudge: Decodable { let line: String?; let about: String?; let eventId: String? }
struct Rated: Decodable { let ok: Bool?; let line: String? }
struct Heard: Decodable { let text: String? }
/// GET /api/evi/status: whether a call can be placed, and today's allowance.
struct EviStatus: Decodable {
    let enabled: Bool?; let engine: String?; let minutesToday: Double?; let cap: Double?; let reason: String?
    /// Her sleep, for standby: asleep now, and when she wakes (ISO 8601) if she is.
    let asleep: Bool?; let wakesAt: String?
}
struct Staged: Decodable { let attachment: JSONValue }
struct Okay: Decodable { let ok: Bool? }
/// POST /api/hearing: the pair she kept from a correction, if there was one to keep.
struct HearingTaught: Decodable { let learned: HearingPair?; let count: Int? }
struct HearingPair: Decodable { let heard: String; let meant: String }
/// GET /api/hearing: what she has been taught she mishears, and how often each has fired.
struct HearingPage: Decodable { let corrections: [HearingRule] }
struct HearingRule: Decodable, Identifiable { let heard: String; let meant: String; let used: Int?; var id: String { heard } }
/// For calls whose answer is not needed, only that they went through.
struct Ignored: Decodable {}
/// POST /api/chat's answer: her line, or nothing when she let it pass.
struct Said: Decodable { let reply: String?; let ignored: Bool? }
struct ServerError: Decodable { let error: String? }
struct MemoryPage: Decodable { let memories: [String] }
struct LookedUp: Decodable { let name: String? }

// MARK: Status

struct Meter: Codable, Identifiable {
    let key: String
    let label: String
    /// 0–100.
    let value: Double
    let note: String
    var id: String { key }
}

struct Bond: Codable {
    let value: Double
    let level: Double
    let of: Double
    let title: String
    let note: String
    let toNext: Double
}

struct Grudge: Codable { let value: Double; let of: Double; let note: String }

struct WaitingItem: Codable, Identifiable {
    let id: String
    let title: String
    /// "today", "tomorrow", "Thursday, 3 days from now" — never a bare date.
    let when: String
    let late: Bool
}

struct Standing: Codable {
    /// In her own sleeping hours (absent from a server older than 2026-09-19).
    let asleep: Bool?
    let emotion: String
    let face: String
    let mood: String
    let bond: Bond
    let meters: [Meter]
    let patience: Meter
    let grudge: Grudge
    let knownDays: Double
    let daysTalked: Double
    let minutesSinceSpoke: Double?
    let waiting: [WaitingItem]
    let stale: [WaitingItem]
}

// MARK: Diary, Her

struct DiaryEntry: Decodable, Identifiable {
    let day: String
    let title: String
    let text: String
    var id: String { day + "|" + title }
}
struct DiaryPage: Decodable { let entries: [DiaryEntry] }

struct HerThing: Decodable, Identifiable {
    let name: String
    let kind: String
    let since: String
    let nights: Double
    let because: String
    let stance: String
    let favourite: String?
    let wants: String?
    var id: String { name }
}

struct Adventure: Decodable, Identifiable {
    let day: String
    let at: String
    let about: String
    let why: String
    let note: String?
    let sources: [String]?
    var id: String { at + "|" + about }
}

struct Liked: Decodable, Identifiable { let name: String; let of: String; var id: String { of + "|" + name } }
struct Wanted: Decodable, Identifiable { let wish: String; let of: String; var id: String { of + "|" + wish } }

struct Her: Decodable {
    struct Diary: Decodable {
        struct Latest: Decodable { let day: String; let title: String }
        let entries: Double
        let since: String?
        let latest: Latest?
    }
    struct NightsOut: Decodable { let count: Double; let first: String? }
    let things: [HerThing]
    let adventures: [Adventure]
    let likes: [Liked]
    let wants: [Wanted]
    let diary: Diary
    let nightsOut: NightsOut
}

// MARK: Agenda

struct AgendaItem: Decodable, Identifiable {
    let id: String
    let title: String
    let date: String
    let time: String?
    let kind: String
    let done: Bool?
    let daysAway: Double
}
struct AgendaPage: Decodable { let items: [AgendaItem] }

// MARK: Whereabouts

/// What the server tells a page about where they are: never coordinates. The
/// phone holds those; this is a place name if the last fix landed in one,
/// whether that fix is recent, the network it came over, and the named places.
struct Whereabouts: Decodable {
    let enabled: Bool
    let at: String?
    let fresh: Bool
    let net: String?
    let places: [String]
}

// MARK: Body

/// GET /api/body: the switch, and the last figures the phone sent.
struct BodyState: Decodable {
    let enabled: Bool
    let at: String?
    let fresh: Bool
    let day: String?
    let sleepMinutes: Double?
    let steps: Double?
}

// MARK: Push preferences

struct PushPrefs: Codable, Equatable {
    var random: Bool
    var events: Bool
    var system: Bool
    var weather: Bool
    var quietFrom: String
    var quietTo: String
    var upBy: String
    /// Set by the Focus filter, not the sheet: her nudges are held while a
    /// Focus with it is on. Read for the row that says so; never sent back.
    var held: Bool?

    var body: [String: JSONValue] {
        [
            "random": .bool(random), "events": .bool(events), "system": .bool(system), "weather": .bool(weather),
            "quietFrom": .string(quietFrom), "quietTo": .string(quietTo), "upBy": .string(upBy),
        ]
    }
}
struct PushInfo: Decodable { let key: String?; let prefs: PushPrefs }
struct PushPrefsPage: Decodable { let prefs: PushPrefs }

// MARK: Her face

/// The SVG face to show for a mood. The desktop's MOOD_TO_EMOTION, kept here so
/// /api/expression's `emotion` and /api/status's `face` both find a file under
/// /emotions/<name>.svg.
enum Face {
    static let byMood: [String: String] = [
        "neutral": "neutral", "happy": "happy", "curious": "curious", "smug": "smug",
        "annoyed": "annoyed", "bored": "annoyed", "sleepy": "sleepy", "surprised": "surprised",
        "affectionate": "love", "embarrassed": "embarrassed", "determined": "excited", "worried": "sad",
    ]
    static func file(for emotion: String) -> String {
        if let mapped = byMood[emotion] { return mapped }
        if byMood.values.contains(emotion) { return emotion }
        return "neutral"
    }
}
