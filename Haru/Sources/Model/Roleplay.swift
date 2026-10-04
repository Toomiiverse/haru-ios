import Foundation

struct VeniceCharacter: Codable, Identifiable, Equatable, Sendable {
    var id: String { slug }
    let creator: CreatorFields?
    let custom: Bool?
    let profileId: String?
    let profileRevision: Int?
    let instructions: String?
    let background: String?
    let slug: String
    let name: String
    let description: String
    let photoUrl: String
    let shareUrl: String
    let tags: [String]
    let adult: Bool
    let catalogModel: String
    let model: String
}
struct RoleplayMessage: Codable, Identifiable, Sendable {
    let id: String
    let role: String
    let content: String
}
struct RoleplayState: Codable, Sendable {
    let mode: String
    let revision: Int
    let character: VeniceCharacter?
    let sceneId: String?
    let messages: [RoleplayMessage]
    let pendingRequestId: String?
    let error: String?
    let model: String
}
struct CharacterCatalog: Codable, Sendable {
    let characters: [VeniceCharacter]
    let offset: Int
    let hasMore: Bool
    let model: String
}
struct RoleplayReceipt: Codable, Sendable {
    let requestId: String
    let status: String
    let reply: String?
    let error: String?
    let sceneId: String?
}

struct CreatorDocument: Codable, Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var text: String
}
struct CreatorFields: Codable, Equatable, Sendable {
    var avatarData = ""
    var tags: [String] = []
    var intro = ""
    var systemPrompts: [String] = []
    var documents: [CreatorDocument] = []
    var memoryDocuments: [CreatorDocument] = []
    var notes = ""
    var extraction = ""
    var insightsEnabled = false
    var insights: [String: [String: String]] = [:]
    var model = "venice-uncensored-1-2"
    var temperature = 0.85
    var maxTokens = 768
    var normalized: CreatorFields {
        var result = self
        result.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        result.systemPrompts = systemPrompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return result
    }
}
struct VeniceModel: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let contextTokens: Int
    let maxTokens: Int
    let inputUsdPerMillion: Double
    let outputUsdPerMillion: Double
    let privacy: String
    let reasoning: Bool
}
struct VeniceModels: Codable, Sendable { let models: [VeniceModel]; let `default`: String }
struct HaruReference: Codable, Identifiable, Sendable {
    let id: String
    let revision: Int
    let label: String
    let guidance: String
    let transcript: String
    let characterName: String
    let sceneId: String
}
struct HaruReferences: Codable, Sendable { let references: [HaruReference] }
struct GeneratedCharacter: Codable, Sendable {
    let name: String
    let description: String?
    let instructions: String
    let intro: String?
    let tags: [String]?
}
