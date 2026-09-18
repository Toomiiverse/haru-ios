import SwiftUI
import UIKit
import WidgetKit

/// Her, on the home screen and the lock screen: her face, the face she is
/// pulling, her mood in her own words, and the meters — from /api/status,
/// fetched with the cookie the app leaves in the App Group on WidgetKit's
/// clock; the app's own last snapshot fills in until then. Taps go through
/// haru:// to the right screen.
@main
struct HaruWidgetBundle: WidgetBundle {
    var body: some Widget {
        HaruStatusWidget()
        HaruListWidget()
        HaruLiveActivity()
        if #available(iOSApplicationExtension 18.0, *) {
            HaruCallControl()
            HaruStandbyControl()
        }
    }
}

struct HaruEntry: TimelineEntry {
    let date: Date
    let standing: Standing?
    let portrait: UIImage?
    /// The figures are the app's last, not a fresh fetch.
    let stale: Bool
}

struct HaruProvider: TimelineProvider {
    func placeholder(in context: Context) -> HaruEntry {
        HaruEntry(date: Date(), standing: Shared.standing?.standing, portrait: cachedPortrait(), stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (HaruEntry) -> Void) {
        completion(HaruEntry(date: Date(), standing: Shared.standing?.standing, portrait: cachedPortrait(), stale: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HaruEntry>) -> Void) {
        Task {
            let live = await fetchStanding()
            if let live { Shared.store(standing: live) }
            let portrait = await fetchPortrait() ?? cachedPortrait()
            let entry = HaruEntry(date: Date(), standing: live ?? Shared.standing?.standing, portrait: portrait, stale: live == nil)
            // Sooner when the fetch failed (off the tailnet, most likely), so
            // the figures catch up not long after the phone is back.
            let next = Date().addingTimeInterval(live == nil ? 15 * 60 : 30 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    /// Its own short-fused session, with no jar: the cookie goes on by hand.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    private func fetchStanding() async -> Standing? {
        guard let base = Shared.base, let cookie = Shared.cookie else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("api/status"))
        request.setValue("\(Shared.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        guard let (data, response) = try? await Self.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Standing.self, from: data)
    }

    /// Her picture is public on the server; kept in the group for the next
    /// time, and for when the fetch fails.
    private func fetchPortrait() async -> UIImage? {
        guard let base = Shared.base else { return nil }
        guard let (data, response) = try? await Self.session.data(from: base.appendingPathComponent("portrait")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        Shared.portrait = data
        return image
    }

    private func cachedPortrait() -> UIImage? {
        Shared.portrait.flatMap { UIImage(data: $0) }
    }
}

struct HaruStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.toomiiverse.haru.status", provider: HaruProvider()) { entry in
            HaruWidgetView(entry: entry)
                .containerBackground(for: .widget) { Theme.ground }
        }
        .configurationDisplayName("Haru")
        .description("How she is, and where you stand.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// The page's ground and accent (its --bg, --bg-lift and --accent, OKLCH at
/// hue 350), as sRGB — the widget has no asset catalogue of its own.
enum Theme {
    static let bg = Color(red: 0.094, green: 0.026, blue: 0.060)
    static let lift = Color(red: 0.154, green: 0.058, blue: 0.106)
    static let accent = Color(red: 0.962, green: 0.579, blue: 0.765)
    static var ground: some View {
        LinearGradient(colors: [lift, bg], startPoint: .top, endPoint: .bottom)
    }
}

struct HaruWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HaruEntry

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    private var emotion: String { entry.standing?.emotion ?? "neutral" }
    private var energy: Double { meter("Energy") ?? 0 }
    private func meter(_ label: String) -> Double? {
        entry.standing?.meters.first { $0.label == label }?.value
    }

    private var face: some View {
        Group {
            if let portrait = entry.portrait {
                Image(uiImage: portrait).resizable().scaledToFill()
            } else {
                Image(systemName: MoodLook.symbol(for: emotion))
                    .font(.title)
                    .foregroundStyle(MoodLook.tint(for: emotion))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                face
                Spacer()
                Image(systemName: MoodLook.symbol(for: emotion))
                    .foregroundStyle(MoodLook.tint(for: emotion))
            }
            Spacer(minLength: 0)
            Text(emotion.capitalized).font(.headline)
            if let bond = entry.standing?.bond {
                Text("\(bond.title) · Lv \(Int(bond.level))").font(.caption2).foregroundStyle(.secondary)
            }
            bar("Energy", energy, tint: MoodLook.tint(forMeter: "Energy"))
        }
        .widgetURL(URL(string: "haru://chat"))
    }

    private var medium: some View {
        HStack(spacing: 14) {
            Link(destination: URL(string: "haru://chat")!) {
                VStack(spacing: 4) {
                    face
                    Text("Haru").font(.caption.weight(.semibold))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: MoodLook.symbol(for: emotion))
                        .font(.caption)
                        .foregroundStyle(MoodLook.tint(for: emotion))
                    Text(emotion.capitalized).font(.headline)
                    Spacer()
                    Link(destination: URL(string: "haru://talk")!) {
                        Image(systemName: "mic.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                    }
                }
                Text(entry.standing?.mood ?? (entry.stale ? "Her figures are the app's last." : "Open the app to sign in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Link(destination: URL(string: "haru://status")!) {
                    HStack(spacing: 10) {
                        if let bond = entry.standing?.bond {
                            bar("\(bond.title) Lv \(Int(bond.level))", bond.level / max(bond.of, 1) * 100, tint: Theme.accent)
                        }
                        if let affection = meter("Affection") {
                            bar("Affection", affection, tint: MoodLook.tint(forMeter: "Affection"))
                        }
                        bar("Energy", energy, tint: MoodLook.tint(forMeter: "Energy"))
                    }
                }
            }
        }
    }

    private func bar(_ label: String, _ value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(tint).frame(width: geo.size.width * CGFloat(min(max(value / 100, 0), 1)))
                }
            }
            .frame(height: 4)
        }
    }

    private var circular: some View {
        Gauge(value: energy, in: 0...100) {
            Image(systemName: MoodLook.symbol(for: emotion))
        } currentValueLabel: {
            Text("\(Int(energy))").font(.caption2)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(URL(string: "haru://chat"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: MoodLook.symbol(for: emotion))
                Text("Haru · \(emotion.capitalized)").font(.headline)
            }
            Text(entry.standing?.mood ?? "").font(.caption2).lineLimit(2)
        }
        .widgetURL(URL(string: "haru://chat"))
    }

    private var inline: some View {
        let bond = entry.standing.map { " · Lv \(Int($0.bond.level))" } ?? ""
        return Text("Haru · \(emotion.capitalized)\(bond)")
            .widgetURL(URL(string: "haru://chat"))
    }
}
