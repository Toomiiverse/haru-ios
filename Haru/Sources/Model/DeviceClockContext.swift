import Foundation

/// A timezone fact; Haru Core uses its trusted UTC clock for the actual time.
enum DeviceClockContext {
    static var timeZone: String { TimeZone.autoupdatingCurrent.identifier }

    static func callHello(zone: String = timeZone) -> String {
        let facts: [String: Any] = ["type": "hello", "pcm": true,
            "reactionActivityTracked": true, "timeZone": zone]
        // Every value is a primitive accepted by JSONSerialization.
        let data = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
