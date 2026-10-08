import Foundation

/// A scene may activate repeatedly during one connection. Only its first start briefs the driver.
struct DriveState {
    private(set) var connected = false
    private(set) var visible = false
    private(set) var running = false
    private(set) var briefed = false

    mutating func connect() { self = DriveState(); connected = true }
    mutating func activate() { visible = connected }
    mutating func begin() -> Bool {
        guard connected, visible, !running else { return false }
        running = true
        return true
    }
    mutating func didBrief() { briefed = true }
    mutating func stop() { running = false }
    mutating func resign() { visible = false; stop() }
    mutating func disconnect() { self = DriveState() }

    static func mapsURL(latitude: Double, longitude: Double) -> URL? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        var parts = URLComponents(string: "https://maps.apple.com/")!
        parts.queryItems = [URLQueryItem(name: "daddr", value: "\(latitude),\(longitude)"),
                            URLQueryItem(name: "dirflg", value: "d")]
        return parts.url
    }

    static let briefing = """
    I'm starting a drive with you in CarPlay. Greet me in your own voice. Give me a brief spoken summary of the current weather and today's outstanding reminders, using only enabled phone tools and actual results. Skip unavailable data; never invent it. Credit Apple Weather if you use it. Keep the whole briefing under about 30 seconds, then ask where I'm going. While we're driving, keep replies concise and spoken. For directions use ios_maps; a prepared route still needs my Navigate tap in CarPlay, and is not proof navigation has started. Do not ask me to handle my phone while driving.
    """
}
