import Foundation

/// One card in coding mode, as electron/codemode.ts sends it: a prompt of his ("you"), the coder's
/// text ("said"), a tool step, a permission ask, or an error. Events carry the same fields and are
/// merged into the card with the same kind and id.
struct CodeItem: Decodable, Identifiable, Equatable {
    var kind: String
    var id: String
    var text: String?
    var name: String?
    var status: String?
    var title: String?
    var output: String?
    var patch: String?
    var exit: Int?
    var resources: [String]?
    var reply: String?

    /// The event's non-empty fields over this card's.
    mutating func merge(_ f: CodeFrame) {
        if let v = f.text { text = v }
        if let v = f.name, !v.isEmpty { name = v }
        if let v = f.status { status = v }
        if let v = f.title, !v.isEmpty { title = v }
        if let v = f.output { output = v }
        if let v = f.patch { patch = v }
        if let v = f.exit { exit = v }
        if let v = f.resources { resources = v }
        if let v = f.reply { reply = v }
        if let d = f.delta { text = (text ?? "") + d }
    }
}

/// "/code" or "/code <folder>" typed to her: the folder ("" for none), else nil.
func codeCommand(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t == "/code" || t.hasPrefix("/code ") else { return nil }
    return String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
}

/// "!command" typed in coding mode: the command to run in the project folder, else nil.
func terminalCommand(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("!") else { return nil }
    return String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
}

struct CodeModel: Decodable, Hashable { let id: String; let name: String }
struct CodeSpent: Decodable, Equatable { let today: Double; let cap: Double }

/// Everything the stream or /api/code/state can say; which fields are set depends on `kind`.
struct CodeFrame: Decodable {
    var kind: String?
    var id: String?
    var text: String?
    var delta: String?
    var name: String?
    var status: String?
    var title: String?
    var output: String?
    var patch: String?
    var exit: Int?
    var resources: [String]?
    var reply: String?
    var running: Bool?
    var error: String?
    var note: String?
    var tokens: Int?
    var folder: String?
    var model: String?
    var models: [CodeModel]?
    var projects: [String]?
    var sessionId: String?
    var items: [CodeItem]?
    var spent: CodeSpent?
}

struct CodeFileDiff: Decodable, Identifiable { let file: String; let additions: Int; let deletions: Int; let patch: String; var id: String { file } }
struct CodeDiff: Decodable { let files: [CodeFileDiff]; let untracked: [String] }
struct CodeOK: Decodable {}

/// One of his earlier coding-mode sessions (GET /api/code/sessions).
struct CodeSessionRow: Decodable, Identifiable, Equatable {
    let id: String
    let folder: String
    let task: String
    let at: String
    let updatedAt: String
    let model: String?
    let archived: Bool
    let current: Bool

    /// When it was last worked on; the server sends ISO 8601 with milliseconds.
    var updated: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt)
    }
}
struct CodeSessions: Decodable { let sessions: [CodeSessionRow] }
