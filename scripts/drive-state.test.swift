import Foundation

@main struct DriveStateTests {
    static func main() {
        var drive = DriveState()
        assert(!drive.begin(), "Disconnected scenes must not start the microphone")
        drive.connect()
        assert(!drive.begin(), "A connected background scene must not start")
        drive.activate()
        assert(drive.automaticStartAvailable)
        assert(drive.begin())
        assert(!drive.begin(), "Duplicate activation must not start a second session")
        drive.didBrief()
        drive.resign()
        assert(!drive.running && !drive.begin())
        drive.activate()
        assert(!drive.automaticStartAvailable, "Returning from Siri or Maps must require an explicit Talk tap")
        assert(drive.begin() && drive.briefed, "Returning from Maps must not repeat the briefing")
        drive.disconnect()
        assert(!drive.running && !drive.connected)
        drive.connect(); drive.activate()
        assert(drive.automaticStartAvailable)
        assert(drive.begin() && !drive.briefed, "A new drive gets its own greeting")
        assert(DriveState.mapsURL(latitude: .nan, longitude: 0) == nil)
        assert(DriveState.mapsURL(latitude: 0, longitude: 181) == nil)
        let url = DriveState.mapsURL(latitude: -31.95, longitude: 115.86)!
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        assert(parts.host == "maps.apple.com" && parts.scheme == "https")
        assert(parts.queryItems?.first?.value == "-31.95,115.86")
        assert(parts.queryItems?.last?.value == "d")
        print("Drive lifecycle and Maps handoff checks passed")
    }
}
