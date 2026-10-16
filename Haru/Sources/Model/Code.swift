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
