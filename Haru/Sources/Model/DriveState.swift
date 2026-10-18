import Foundation

/// A scene may activate repeatedly during one connection. Only its first start briefs the driver.
struct DriveState {
    private(set) var connected = false
    private(set) var visible = false
    private(set) var running = false
    private(set) var briefed = false
    private var attemptedStart = false
    var automaticStartAvailable: Bool { connected && visible && !attemptedStart }

    mutating func connect(isActive: Bool = false) {
        // UIKit activation and CarPlay's interface connection are separate callbacks.
        // An activation already received must survive the later interface connection.
        let wasVisible = visible
        self = DriveState()
        connected = true
        visible = wasVisible || isActive
    }
    mutating func activate() { visible = true }
    mutating func begin() -> Bool {
        guard connected, visible, !running else { return false }
        attemptedStart = true
        running = true
        return true
    }
    mutating func didBrief() { briefed = true }
    mutating func beginFromTap() -> Bool {
        // A delivered CarPlay button event is evidence that our template is visible.
        // It must not depend on a scene activation callback having arrived first.
        guard connected else { return false }
        activate()
        return begin()
    }
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
}
