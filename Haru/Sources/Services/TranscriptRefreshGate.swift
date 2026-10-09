import Foundation

/// A history response may replace the screen only while both the request and
/// the visible transcript are still current. No history or reply is retried.
@MainActor
final class TranscriptRefreshGate {
    struct Ticket {
        fileprivate let request: UInt64
        fileprivate let revision: UInt64
    }
    private var request: UInt64 = 0
    private var revision: UInt64 = 0

    func invalidate() { revision &+= 1 }
    func begin() -> Ticket {
        request &+= 1
        return Ticket(request: request, revision: revision)
    }
    func isLatest(_ ticket: Ticket) -> Bool { ticket.request == request }
    func accepts(_ ticket: Ticket) -> Bool {
        isLatest(ticket) && ticket.revision == revision
    }
}
