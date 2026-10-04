import Foundation

struct VeniceCharacter: Codable, Identifiable, Equatable, Sendable {
    var id: String { slug }
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
