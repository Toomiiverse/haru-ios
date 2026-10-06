import Foundation

@main struct ClockTests {
    static func main() throws {
        for zone in ["Australia/Perth", "America/New_York", "Pacific/Auckland", "test\"\\zone"] {
            let packet = try JSONSerialization.jsonObject(with: Data(DeviceClockContext.callHello(zone: zone).utf8)) as! [String: Any]
            precondition(packet["type"] as? String == "hello")
            precondition(packet["timeZone"] as? String == zone)
            precondition(packet["pcm"] as? Bool == true)
            precondition(packet["reactionActivityTracked"] as? Bool == true)
        }
        precondition(TimeZone(identifier: DeviceClockContext.timeZone) != nil)
        print("PASS: device timezone and escaped call hello; PCM/activity flags preserved")
    }
}
