import AppIntents
import Foundation

/// Her, from outside the app: Siri, the Shortcuts app, the Action button.
/// Three verbs. "Tell Haru" takes a line and speaks her answer; "Talk to
/// Haru" opens the app with the ear on; "How is Haru" says how she is. They
/// run in the app's own process, so the saved address and the cookie jar are
/// theirs — nothing new on the server. Shortcuts automations (arriving home,
/// the car connecting, the charger) are built from these by the user, with
/// the line set in the automation.

enum HaruIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingToSay
    case signedOut
    case unreachable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingToSay: return "There was nothing to tell her."
        case .signedOut: return "You are signed out of Haru on this phone. Open the app and sign in."
        case .unreachable: return "She could not be reached. Is the phone on the tailnet?"
        }
    }
}

/// A line to her, and her reply back — spoken by Siri, or handed on to the
/// next step of a Shortcut.
struct TellHaruIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Haru"
    static let description = IntentDescription("Send her a line, and hear what she says back.")
    static let openAppWhenRun = false

    @Parameter(title: "Message", requestValueDialog: "What do you want to tell her?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Haru \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { throw HaruIntentError.nothingToSay }
        let said: Said
        do {
            said = try await Session.savedClient(quick: true).post("/api/chat", ["text": .string(line)])
        } catch HaruError.signedOut {
            throw HaruIntentError.signedOut
        } catch {
            throw HaruIntentError.unreachable
        }
        let reply = (said.reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = reply.isEmpty ? "She read it and said nothing." : reply
        return .result(value: reply, dialog: IntentDialog("\(spoken)"))
    }
}

/// The app, open on the chat, listening — the Action button's job.
struct TalkToHaruIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Haru"
    static let description = IntentDescription("Open Haru with the ear on, ready to listen.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Navigator.shared.tab = .chat
        Navigator.shared.wantsTalk = true
        return .result()
    }
}

/// How she is right now, in a sentence Siri can say.
struct HowIsHaruIntent: AppIntent {
    static let title: LocalizedStringResource = "How Is Haru"
    static let description = IntentDescription("How she is right now: her mood, and where you stand.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let standing: Standing
        do {
            standing = try await Session.savedClient(quick: true).get("/api/status")
        } catch HaruError.signedOut {
            throw HaruIntentError.signedOut
        } catch {
            throw HaruIntentError.unreachable
        }
        var parts = ["She's \(standing.emotion)."]
        let mood = standing.mood.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mood.isEmpty { parts.append(mood) }
        parts.append("You're \(standing.bond.title.lowercased()), level \(Int(standing.bond.level)) of \(Int(standing.bond.of)).")
        if let energy = standing.meters.first(where: { $0.label == "Energy" }) {
            parts.append("Energy \(Int(energy.value.rounded())) of a hundred.")
        }
        if standing.grudge.value > 0 { parts.append(standing.grudge.note) }
        let line = parts.joined(separator: " ")
        return .result(value: line, dialog: IntentDialog("\(line)"))
    }
}

/// Her part in a Focus. Added under Settings → Focus → (a Focus) → Add Filter →
/// Haru; iOS calls this when that Focus turns on with what was chosen, and
/// again with the defaults when it turns off — so the default is the everyday
/// state, nudges as usual, and only a Focus set to hold her holds her.
struct HaruFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Haru"
    static let description = IntentDescription("Whether she holds her nudges while this Focus is on.")

    @Parameter(title: "Hold her nudges", default: false)
    var hold: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: hold ? "Nudges held" : "Nudges as usual")
    }

    func perform() async throws -> some IntentResult {
        do {
            let _: Ignored = try await Session.savedClient(quick: true).post("/api/push/prefs", ["held": .bool(hold)])
        } catch HaruError.signedOut {
            throw HaruIntentError.signedOut
        } catch {
            throw HaruIntentError.unreachable
        }
        return .result()
    }
}

/// The phrases Siri answers to, and the tiles in the Shortcuts app.
struct HaruShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TellHaruIntent(),
            phrases: ["Tell \(.applicationName)", "Message \(.applicationName)", "Say something to \(.applicationName)"],
            shortTitle: "Tell Haru",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
        AppShortcut(
            intent: TalkToHaruIntent(),
            phrases: ["Talk to \(.applicationName)", "Call \(.applicationName)", "Open \(.applicationName) and listen"],
            shortTitle: "Talk to Haru",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: HowIsHaruIntent(),
            phrases: ["How is \(.applicationName)", "How's \(.applicationName)", "How is \(.applicationName) doing"],
            shortTitle: "How is Haru",
            systemImageName: "heart.text.square.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .pink
}
