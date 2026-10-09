import Foundation
import Observation

/// Read-only presentation state. A failed refresh never leaves old feelings looking current.
@MainActor @Observable
final class AffectStatus {
    private(set) var snapshot: AffectSettings?
    private(set) var problem: String?
    private(set) var loading = false
    private var request = UUID()

    func refresh(client: HaruClient) async throws {
        let token = UUID()
        request = token
        snapshot = nil
        problem = nil
        loading = true
        defer { if request == token { loading = false } }
        do {
            let value: AffectSettings = try await client.get("/api/affect/settings")
            guard request == token, !Task.isCancelled else { return }
            snapshot = value
        } catch {
            guard request == token, !Task.isCancelled else { return }
            problem = "Current feelings couldn’t be refreshed. Try again."
            throw error
        }
    }
}
