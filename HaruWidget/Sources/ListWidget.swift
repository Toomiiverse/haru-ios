import AppIntents
import SwiftUI
import WidgetKit

/// Her list on the home screen, with a circle to tick a thing off where it
/// sits — no app, no unlock beyond the home screen's own. The same routes the
/// app uses (/api/agenda, /api/agenda/done), with the cookie from the App
/// Group like the status widget. The lock-screen size shows the next thing
/// only: iOS gives those no buttons.
struct ListEntry: TimelineEntry {
    let date: Date
    let items: [AgendaItem]
    /// The fetch landed; false means these are the last ones seen.
    let reached: Bool
}

enum ListDoor {
    private static let cacheKey = "list"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    /// What is still open, soonest first; overdue things lead.
    static func open(_ items: [AgendaItem]) -> [AgendaItem] {
        items.filter { $0.done != true }.sorted { ($0.daysAway, $0.time ?? "") < ($1.daysAway, $1.time ?? "") }
    }

    static var cached: [AgendaItem] {
        guard let data = Shared.defaults?.data(forKey: cacheKey),
              let page = try? JSONDecoder().decode(AgendaPage.self, from: data) else { return [] }
        return open(page.items)
    }

    private static func send(_ path: String, body: [String: String]? = nil) async -> [AgendaItem]? {
        guard let base = Shared.base, let cookie = Shared.cookie else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("\(Shared.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let page = try? JSONDecoder().decode(AgendaPage.self, from: data) else { return nil }
        Shared.defaults?.set(data, forKey: cacheKey)
        return open(page.items)
    }

    static func fetch() async -> [AgendaItem]? { await send("api/agenda") }
    static func tick(_ id: String) async -> [AgendaItem]? { await send("api/agenda/done", body: ["id": id]) }
}

/// The circle beside an item. Runs in the widget extension; WidgetKit reloads
/// the timeline when it returns, and the answer is already in the cache.
struct TickItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Tick off"
    static let isDiscoverable = false

    @Parameter(title: "Item")
    var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        _ = await ListDoor.tick(id)
        return .result()
    }
}

struct ListProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListEntry { ListEntry(date: Date(), items: ListDoor.cached, reached: true) }

    func getSnapshot(in context: Context, completion: @escaping (ListEntry) -> Void) {
        completion(ListEntry(date: Date(), items: ListDoor.cached, reached: true))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListEntry>) -> Void) {
        Task {
            let live = await ListDoor.fetch()
            let entry = ListEntry(date: Date(), items: live ?? ListDoor.cached, reached: live != nil)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(live == nil ? 15 * 60 : 30 * 60))))
        }
    }
}

struct HaruListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.toomiiverse.haru.list", provider: ListProvider()) { entry in
            HaruListView(entry: entry)
                .containerBackground(for: .widget) { Theme.ground }
        }
        .configurationDisplayName("Her list")
        .description("What she is keeping for you, with a circle to tick it off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct HaruListView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ListEntry

    private var room: Int {
        switch family {
        case .systemLarge: return 7
        case .systemMedium: return 3
        default: return 2
        }
    }

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                Label("Haru’s list", systemImage: "checklist").font(.caption2).widgetAccentable()
                if let next = entry.items.first {
                    Text(next.title).font(.headline).lineLimit(1)
                    Text(when(next)).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Nothing open").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(URL(string: "haru://status"))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Her list").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Spacer()
                    if !entry.reached { Image(systemName: "wifi.slash").font(.caption2).foregroundStyle(.secondary) }
                }
                if entry.items.isEmpty {
                    Spacer(minLength: 0)
                    Text(Shared.cookie == nil ? "Open the app to sign in." : "Nothing open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(entry.items.prefix(room)) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Button(intent: TickItemIntent(id: item.id)) {
                                Image(systemName: "circle").font(.body).foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text(when(item))
                                    .font(.caption2)
                                    .foregroundStyle(item.daysAway < 0 ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.secondary))
                            }
                        }
                    }
                    if entry.items.count > room {
                        Text("and \(entry.items.count - room) more").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(URL(string: "haru://status"))
        }
    }

    private func when(_ item: AgendaItem) -> String {
        let day: String
        switch item.daysAway {
        case ..<0: day = "Overdue"
        case 0..<1: day = "Today"
        case 1..<2: day = "Tomorrow"
        default: day = "In \(Int(item.daysAway)) days"
        }
        return item.time.map { "\(day) · \($0)" } ?? day
    }
}
