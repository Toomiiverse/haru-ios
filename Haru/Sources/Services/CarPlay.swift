import AVFoundation
import CarPlay
import MapKit
import Observation
import OSLog

/// Both scenes use HaruRuntime's conversation; connecting a car never creates a second microphone engine.
@available(iOS 26.4, *)
@MainActor final class HaruCarPlayScene: NSObject, CPTemplateApplicationSceneDelegate {
    private weak var scene: CPTemplateApplicationScene?
    private var controller: CPInterfaceController?
    private let logger = Logger(subsystem: "Haru", category: "CarPlay")
    private var failureState: String?
    private var voice: CPVoiceControlTemplate?
    /// The layout of the template on the car, the state it shows, and when that last changed.
    private var screen: CarScreen?
    private var shown: String?
    private var presenting = false
    private var lastSwitch = Date.distantPast
    private var pendingSwitch: Task<Void, Never>?
    private static let switchSeconds: TimeInterval = 0.4
    /// After CarPlay refuses a template, the next attempt waits; retrying at once could loop.
    private var rebuildAfter = Date.distantPast
    private var drive = DriveState()
    private var starting: Task<Void, Never>?
    private var opening = false
    private var ready = false
    private var startupID = UUID()
    private var route: (url: URL, expires: Date)?
    /// A call that never answers: the screen would say Connecting for ever, since the
    /// startup deadline ends once the call is placed. Twenty seconds, then a retry state.
    private var connectWatch: Task<Void, Never>?
    private static let connectSeconds: Double = 20
    private var runtime: HaruRuntime { .shared }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        scene = templateApplicationScene
        controller = interfaceController
        drive.connect(isActive: templateApplicationScene.activationState == .foregroundActive)
        runtime.chat.inCarPlay = true
        runtime.chat.onCarPlayInterruption = { [weak self] in self?.stop() }
        Audio.carPlay = true
        update()
        observe()
    }

    private static let labels: [String: (title: String, symbol: String)] = [
        "ready": ("Talk to Haru", "mic.fill"),
        "connecting": ("Connecting", "antenna.radiowaves.left.and.right"),
        "listening": ("Listening", "mic.fill"),
        "thinking": ("Thinking", "ellipsis"),
        "speaking": ("Speaking", "waveform"),
        "unavailable": ("Haru is unavailable. Tap Talk to retry", "exclamationmark.circle"),
        "network": ("Check your connection when parked", "wifi.exclamationmark"),
        "account": ("Sign in to Haru on your phone when parked", "person.crop.circle.badge.exclamationmark"),
        "microphone": ("Allow microphone access on your phone when parked", "mic.slash"),
        "busy": ("Finish the current reply, then tap Talk", "ellipsis"),
        "timeout": ("Connection timed out. Tap Talk to retry", "clock.badge.exclamationmark")]

    /// Her face on the car screen for Talk and the live states (CarPlay shows a voice control state image
    /// at up to 150 pt; these are 450 px at 3x). The failure states keep their symbols so the message reads.
    private static let pictures: [String: UIImage] = Dictionary(uniqueKeysWithValues: (["ready"] + CarScreen.live).compactMap { name in
        Bundle.main.url(forResource: "car-" + name, withExtension: "png")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { UIImage(data: $0, scale: 3) }
            .map { (name, $0) }
    })

    /// A voice control template for one layout, opening on `first`. Each state keeps
    /// its buttons and handlers for the template's lifetime.
    private func makeTemplate(_ layout: CarScreen, first: String) -> CPVoiceControlTemplate {
        let owner = scene
        let states = layout.ordered(first: first).map { identifier -> CPVoiceControlState in
            let label = Self.labels[identifier] ?? (title: identifier.capitalized, symbol: "waveform")
            let state = CPVoiceControlState(identifier: identifier, titleVariants: [label.title],
                                            image: Self.pictures[identifier] ?? UIImage(systemName: label.symbol), repeats: false)
            let idle = CarScreen.idle.contains(identifier)
            // CarPlay delivers button presses on its XPC queue, not the main thread. Everything
            // below touches the chat store and her stage web view, which are main-actor only;
            // a tap handled in place crashed the app in WebKit (build 166, 2026-10-11).
            let conversation = CPButton(image: UIImage(systemName: idle ? "mic.fill" : "stop.fill")!) { [weak self, weak owner] _ in
                Task { @MainActor in
                    guard let self, let owner, self.scene === owner else { return }
                    if idle { self.start(fromTap: true) } else { self.stop() }
                }
            }
            conversation.title = idle ? "Talk" : "End conversation"
            var buttons = [conversation]
            if layout.hasRoute {
                let navigate = CPButton(image: UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill")!) { [weak self, weak owner] _ in
                    Task { @MainActor in
                        guard let self, let owner, self.scene === owner else { return }
                        self.navigate()
                    }
                }
                navigate.title = "Navigate"
                buttons.insert(navigate, at: 0)
            }
            state.actionButtons = buttons
            return state
        }
        return CPVoiceControlTemplate(voiceControlStates: states)
    }

    /// Puts `identifier` on the car screen: a state switch on the current template, or a
    /// new template when this one does not carry the state or the Navigate button.
    private func show(_ identifier: String, hasRoute: Bool) {
        guard let controller, let scene else { return }
        // Activating before the template is up has no effect; the completion shows the latest state.
        guard !presenting else { return }
        let layout = CarScreen.layout(showing: identifier, hasRoute: hasRoute, current: screen)
        if layout != screen || voice == nil {
            let backoff = rebuildAfter.timeIntervalSinceNow
            if backoff > 0 {
                if pendingSwitch == nil { later(backoff) }
                return
            }
            pendingSwitch?.cancel(); pendingSwitch = nil
            let template = makeTemplate(layout, first: identifier)
            screen = layout
            voice = template
            shown = identifier
            lastSwitch = Date()
            presenting = true
            controller.setRootTemplate(template, animated: false) { [weak self, weak scene] success, error in
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, let scene, self.scene === scene else { return }
                    self.presenting = false
                    if success {
                        self.ready = true
                        if self.drive.automaticStartAvailable { self.start() } else { self.update() }
                    } else {
                        self.logger.error("CarPlay refused the template: \(message ?? "no reason", privacy: .public)")
                        self.screen = nil; self.voice = nil; self.shown = nil
                        self.rebuildAfter = Date().addingTimeInterval(5)
                        self.runtime.chat.notice = message ?? "CarPlay could not open Haru."
                    }
                }
            }
            return
        }
        guard identifier != shown else { pendingSwitch?.cancel(); pendingSwitch = nil; return }
        // CarPlay ignores state changes that come too quickly; the latest wins after a short wait.
        let wait = Self.switchSeconds - Date().timeIntervalSince(lastSwitch)
        if wait <= 0 {
            pendingSwitch?.cancel(); pendingSwitch = nil
            voice?.activateVoiceControlState(withIdentifier: identifier)
            shown = identifier
            lastSwitch = Date()
        } else if pendingSwitch == nil {
            later(wait)
        }
    }

    /// Shows whatever the latest state is after `seconds`.
    private func later(_ seconds: TimeInterval) {
        pendingSwitch = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self else { return }
            self.pendingSwitch = nil
            self.update()
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        drive.activate()
        activatePhoneTools()
        if ready, drive.automaticStartAvailable { start() }
        else { update() }
    }

    private func activatePhoneTools() {
        PhoneTools.shared.activity(carPlayActive: true)
        PhoneTools.shared.carPlayDirections = { [weak self] destination, mode, expires in
            guard let self else { throw PhoneTools.Failure("ios_carplay_disconnected") }
            return try await self.prepareTrip(destination: destination, mode: mode, expires: expires)
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        drive.resign()
        stop()
        PhoneTools.shared.activity(carPlayActive: false)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        stop()
        drive.disconnect()
        route = nil
        ready = false
        connectWatch?.cancel(); connectWatch = nil
        PhoneTools.shared.carPlay(state: "disconnected")
        PhoneTools.shared.carPlayDirections = nil
        PhoneTools.shared.activity(carPlayActive: false)
        runtime.chat.inCarPlay = false
        runtime.chat.onCarPlayInterruption = nil
        Audio.carPlay = false
        scene = nil
        voice = nil
        screen = nil
        shown = nil
        presenting = false
        rebuildAfter = .distantPast
        pendingSwitch?.cancel(); pendingSwitch = nil
        controller = nil
        failureState = nil
        if UIApplication.shared.applicationState == .active {
            Task { await runtime.chat.standbyOnActive() }
        }
    }

    private func start(fromTap: Bool = false) {
        if fromTap {
            guard drive.beginFromTap() else { return }
            ready = true
        } else {
            guard ready, drive.begin() else { return }
        }
        activatePhoneTools()
        logger.info("Starting CarPlay conversation; explicit tap: \(fromTap)")
        failureState = nil
        let epoch = UUID()
        startupID = epoch
        opening = true
        runtime.chat.notice = nil
        update()
        starting = Task { [weak self] in
            guard let self else { return }
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(90)) } catch { return }
                guard let self, self.startupID == epoch, self.opening else { return }
                self.stop()
                self.fail("timeout", notice: "Haru took too long to connect. Tap Talk to retry.")
            }
            defer {
                deadline.cancel()
                if self.startupID == epoch { self.opening = false; self.update() }
            }
            let chat = self.runtime.chat
            await chat.setStandby(false, persist: false)
            guard !Task.isCancelled else { return }
            guard !chat.busy else {
                self.fail("busy", notice: "Finish the current reply, then tap Talk.")
                return
            }
            chat.stopDrivingAudio()
            await self.runtime.session.check(quick: true)
            guard !Task.isCancelled, self.drive.visible, self.startupID == epoch else { return }
            guard self.runtime.session.problem == nil else {
                self.fail("network", notice: "Haru could not connect. Check your connection when parked, then tap Talk.")
                return
            }
            guard self.runtime.session.signedIn == true else {
                self.fail("account", notice: "Sign in to Haru on your phone when parked, then tap Talk.")
                return
            }
            // The permission is set up on the phone before driving, never requested on the car display.
            guard AVAudioApplication.shared.recordPermission == .granted else {
                self.fail("microphone", notice: "Allow microphone access for Haru on your phone when parked.")
                return
            }
            // Straight into the call, like a phone call: the car screen goes to Listening as
            // soon as her line answers, and her server greets on answer. The spoken briefing
            // that used to run first kept the car on Connecting for seconds with no sound and,
            // on 2026-10-11, failed outright before the call opened.
            await chat.holdMic()
            guard !Task.isCancelled, self.drive.visible, self.startupID == epoch else { return }
            if chat.call == nil {
                self.fail("unavailable", notice: chat.notice ?? "Haru could not start listening. Tap Talk to retry.")
                chat.audio.releaseSession()
            }
        }
    }

    private func fail(_ state: String, notice: String) {
        logger.error("CarPlay startup failed: \(state, privacy: .public)")
        failureState = state
        drive.stop()
        opening = false
        runtime.chat.notice = notice
        update()
    }

    private func stop() {
        startupID = UUID()
        starting?.cancel()
        starting = nil
        opening = false
        drive.stop()
        runtime.chat.stopDrivingAudio()
        update()
    }

    private func observe() {
        withObservationTracking {
            _ = runtime.chat.callState
            _ = runtime.chat.audio.speaking
            _ = runtime.chat.busy
            _ = runtime.chat.notice
            _ = runtime.session.signedIn
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.scene != nil else { return }
                if self.drive.running, !self.opening, self.runtime.chat.call == nil { self.stop() }
                if !self.opening, self.runtime.session.signedIn == false, self.drive.running { self.stop() }
                self.update()
                self.observe()
            }
        }
    }

    private func update() {
        guard controller != nil else { return }
        let chat = runtime.chat
        let identifier: String
        if chat.notice != nil, !drive.running { identifier = failureState ?? "unavailable" }
        else if opening { identifier = "connecting" }
        else if !drive.running { identifier = "ready" }
        else {
            switch chat.callState {
            case .off: identifier = "connecting"
            case .connecting: identifier = "connecting"
            case .listening: identifier = "listening"
            case .thinking: identifier = "thinking"
            case .speaking: identifier = "speaking"
            }
        }
        let hasRoute = route.map { $0.expires > Date() } ?? false
        show(identifier, hasRoute: hasRoute)
        PhoneTools.shared.carPlay(state: identifier)
        watchConnecting(identifier == "connecting" && !opening && drive.running)
    }

    private func watchConnecting(_ on: Bool) {
        guard on else { connectWatch?.cancel(); connectWatch = nil; return }
        guard connectWatch == nil else { return }
        let epoch = startupID
        connectWatch = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.connectSeconds)) } catch { return }
            guard let self, self.startupID == epoch, !self.opening, self.drive.running, self.runtime.chat.callState == .connecting else { return }
            self.logger.error("CarPlay call never became ready")
            self.stop()
            self.fail("timeout", notice: "Haru's call line did not answer. Tap Talk to retry.")
        }
    }

    private func prepareTrip(destination: String, mode: String, expires: Double) async throws -> [String: Any] {
        guard drive.visible, mode == "driving", PhoneTools.shared.enabled("location") else {
            throw PhoneTools.Failure("ios_driving_location_required")
        }
        route = nil
        update()
        let epoch = startupID
        let location = try await PhoneLocation.shared.current()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = destination
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        let response = try await MKLocalSearch(request: request).start()
        guard response.mapItems.count == 1, let item = response.mapItems.first else {
            return ["ok": false, "error": "ios_ambiguous_location",
                    "candidates": response.mapItems.prefix(5).map { $0.placemark.title ?? $0.name ?? "Unknown place" }]
        }
        let directions = MKDirections.Request()
        directions.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        directions.destination = item
        directions.transportType = .automobile
        let result = try await MKDirections(request: directions).calculateETA()
        guard drive.visible, startupID == epoch, PhoneTools.shared.commandIsCurrent(expires),
              let url = DriveState.mapsURL(latitude: item.placemark.coordinate.latitude,
                                          longitude: item.placemark.coordinate.longitude) else {
            throw PhoneTools.Failure("ios_command_expired")
        }
        route = (url, Date().addingTimeInterval(300))
        update()
        return ["ok": true, "routeReady": true, "handoffAccepted": false, "navigationStarted": NSNull(),
                "destination": item.placemark.title ?? item.name ?? destination,
                "estimatedTravelMinutes": Int(ceil(result.expectedTravelTime / 60)),
                "nextAction": "Tell the driver the destination and estimated travel time; they can tap Navigate in CarPlay."]
    }

    private func navigate() {
        guard drive.visible, let scene, let route, route.expires > Date() else {
            route = nil
            runtime.chat.notice = "The route expired. Ask Haru for directions again."
            update()
            return
        }
        stop()
        scene.open(route.url, options: nil) { [weak self] accepted in
            Task { @MainActor in
                guard let self else { return }
                if !accepted { self.runtime.chat.notice = "Maps could not open. Try again when parked." }
                self.update()
            }
        }
    }
}
