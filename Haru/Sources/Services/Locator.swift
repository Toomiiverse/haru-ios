import CoreLocation
import Network
import Observation

/// Where they are, for her — only while the switch on the server says so. The
/// phone holds the coordinates; the server holds names and a yes or no.
@MainActor @Observable
final class Locator: NSObject, CLLocationManagerDelegate {
    var state: Whereabouts?
    var problem: String?
    private(set) var authorised = false

    private let session: Session
    private let manager = CLLocationManager()
    private let monitor = NWPathMonitor()
    private var net = "unknown"
    private var lastSent = Date.distantPast
    private var lastFix: CLLocation?

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
        manager.requestLocation()
    }

    private func apply() {
        authorised = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
        guard let state else { return }
        if state.enabled {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    private func report(_ fix: CLLocation) async {
        guard state?.enabled == true else { return }
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
            state = try await client.post("/api/where", body)
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A missed fix is not worth a word; the next one comes on its own.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.apply() }
    }
}
