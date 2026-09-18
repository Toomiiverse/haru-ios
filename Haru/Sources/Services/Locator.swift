import CoreLocation
import UIKit
import Network
import Observation

/// Where they are, for her — only while the switch on the server says so. The
/// phone holds the coordinates; the server holds names and a yes or no.
@MainActor @Observable
final class Locator: NSObject, CLLocationManagerDelegate {
    var state: Whereabouts?
    var problem: String?
    private(set) var authorised = false
    /// A fix has gone up since the app opened, so a place can be named.
    private(set) var reported = false

    private let session: Session
    private let manager = CLLocationManager()
    private let monitor = NWPathMonitor()
    private var net = "unknown"
    private var lastSent = Date.distantPast
    private var lastFix: CLLocation?
    /// Whether she may hear where they are with the app closed. Kept on the
    /// phone: it is this phone's permission, not a fact about them.
    private(set) var background = UserDefaults.standard.bool(forKey: "where.background")
    /// "Always" was asked for and iOS gave less; More says so.
    var backgroundRefused: Bool {
        background && manager.authorizationStatus != .authorizedAlways && manager.authorizationStatus != .notDetermined
    }

    init(session: Session) {
        self.session = session
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = path.usesInterfaceType(.wifi) ? "wifi"
                : path.usesInterfaceType(.cellular) ? "cellular"
                : path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "unknown"
            Task { @MainActor in self?.net = kind }
        }
        monitor.start(queue: DispatchQueue(label: "haru.net"))
        // iOS may have launched the app for a location event with no screen to
        // call load(): the delegate is set, so switch the services back on.
        apply()
    }

    private var client: HaruClient { session.client }

    func load() async {
        do {
            state = try await client.get("/api/where")
            apply()
        } catch {
            problem = error.localizedDescription
        }
    }

    func setEnabled(_ on: Bool) async {
        do {
            state = try await client.post("/api/where/prefs", ["enabled": .bool(on)])
            apply()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The app is back in front: send a fresh fix soon rather than waiting out the spacing.
    func wake() {
        guard state?.enabled == true else { return }
        lastSent = .distantPast
        apply()
        manager.requestLocation()
    }

    /// With the app closed too: iOS wakes the app when the phone has moved a
    /// few hundred metres or settled somewhere, and the fix goes up like any
    /// other. The server already turns fixes into arrivals (whereabouts.ts).
    func setBackground(_ on: Bool) {
        background = on
        UserDefaults.standard.set(on, forKey: "where.background")
        if on, manager.authorizationStatus != .authorizedAlways { manager.requestAlwaysAuthorization() }
        apply()
    }

    /// The app has gone to the back: the fine-grained updates stop, and only
    /// the two cheap services below go on. In front again, `wake` and `apply`
    /// bring them back.
    func rest() {
        manager.stopUpdatingLocation()
    }

    private func apply() {
        authorised = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
        // No state yet on a launch iOS made in the background: go by what was last asked for.
        let enabled = state?.enabled ?? UserDefaults.standard.bool(forKey: "where.enabled")
        if let state { UserDefaults.standard.set(state.enabled, forKey: "where.enabled") }
        if enabled {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            if state != nil { manager.startUpdatingLocation() }
        } else {
            manager.stopUpdatingLocation()
        }
        // Significant changes and visits are the two services iOS will relaunch
        // a closed app for; both are coarse and cost next to nothing.
        if enabled, background, manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = true
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        } else {
            manager.allowsBackgroundLocationUpdates = false
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
        }
    }

    private func report(_ fix: CLLocation) async {
        guard state?.enabled ?? UserDefaults.standard.bool(forKey: "where.enabled") else { return }
        // iOS gives a woken app seconds; hold it awake until the fix is up.
        let held = UIApplication.shared.beginBackgroundTask(withName: "haru.where")
        defer { if held != .invalid { UIApplication.shared.endBackgroundTask(held) } }
        // Every two minutes, or sooner when they have clearly moved.
        let moved = lastFix.map { fix.distance(from: $0) > 100 } ?? true
        guard moved || Date().timeIntervalSince(lastSent) > 120 else { return }
        lastSent = Date()
        lastFix = fix
        let body: [String: JSONValue] = [
            "lat": .number(fix.coordinate.latitude),
            "lon": .number(fix.coordinate.longitude),
            "accuracy": .number(max(0, fix.horizontalAccuracy)),
            "net": .string(net),
        ]
        do {
            // Woken in the background, the patient client would wait out the few seconds iOS allows.
            let door = UIApplication.shared.applicationState == .background ? Session.savedClient(quick: true) : client
            state = try await door.post("/api/where", body)
            reported = true
        } catch HaruError.server(let code, _) where code == 409 {
            // Sharing was switched off on the other side; stop asking.
            await load()
        } catch {
            problem = error.localizedDescription
        }
    }

    func name(_ name: String) async {
        do { state = try await client.post("/api/where/name", ["name": .string(name)]) }
        catch { problem = error.localizedDescription }
    }

    func forget(_ name: String) async {
        do { state = try await client.post("/api/where/forget", ["name": .string(name)]) }
        catch { problem = error.localizedDescription }
    }

    func lookUp() async -> String? {
        do {
            let found: LookedUp = try await client.post("/api/where/lookup")
            return found.name
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in await self.report(fix) }
    }

    /// Settled somewhere, or left it. A departure carries no new spot worth
    /// sending; the next significant change says where they went.
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard visit.departureDate == .distantFuture, visit.horizontalAccuracy >= 0 else { return }
        let fix = CLLocation(coordinate: visit.coordinate, altitude: 0, horizontalAccuracy: visit.horizontalAccuracy, verticalAccuracy: -1, timestamp: Date())
        Task { @MainActor in await self.report(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A missed fix is not worth a word; the next one comes on its own.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.apply() }
    }
}
