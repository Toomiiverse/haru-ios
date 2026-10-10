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
    private var states: [CPVoiceControlState] = []
    private var drive = DriveState()
    private var starting: Task<Void, Never>?
    private var opening = false
    private var ready = false
    private var startupID = UUID()
    private var route: (url: URL, expires: Date)?
    private var runtime: HaruRuntime { .shared }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        scene = templateApplicationScene
        controller = interfaceController
        drive.connect(isActive: templateApplicationScene.activationState == .foregroundActive)
        runtime.chat.inCarPlay = true
        runtime.chat.onCarPlayInterruption = { [weak self] in self?.stop() }
        Audio.carPlay = true
        let labels = [("ready", "Talk to Haru", "mic.fill"),
                      ("connecting", "Connecting", "antenna.radiowaves.left.and.right"),
                      ("briefing", "Your drive briefing", "waveform"),
                      ("listening", "Listening", "mic.fill"),
                      ("thinking", "Thinking", "ellipsis"),
                      ("speaking", "Speaking", "waveform"),
                      ("unavailable", "Haru is unavailable. Tap Talk to retry", "exclamationmark.circle"),
                      ("network", "Check your connection when parked", "wifi.exclamationmark"),
                      ("account", "Sign in to Haru on your phone when parked", "person.crop.circle.badge.exclamationmark"),
                      ("microphone", "Allow microphone access on your phone when parked", "mic.slash"),
                      ("busy", "Finish the current reply, then tap Talk", "ellipsis"),
                      ("timeout", "Connection timed out. Tap Talk to retry", "clock.badge.exclamationmark")]
        let idleStates: Set<String> = ["ready", "unavailable", "network", "account", "microphone", "busy", "timeout"]
        // Configure actions before presenting the template. Each displayed state keeps
        // its original buttons and handlers for the lifetime of this connection.
        states = labels.flatMap { identifier, title, symbol in
            [false, true].map { hasRoute in
                let state = CPVoiceControlState(identifier: identifier + (hasRoute ? "_route" : ""),
                                                titleVariants: [title], image: UIImage(systemName: symbol), repeats: false)
                let idle = idleStates.contains(identifier)
                let conversation = CPButton(image: UIImage(systemName: idle ? "mic.fill" : "stop.fill")!) { [weak self, weak templateApplicationScene] _ in
                    guard let self, let templateApplicationScene, self.scene === templateApplicationScene else { return }
                    if idle { self.start(fromTap: true) } else { self.stop() }
                }
                conversation.title = idle ? "Talk" : "End conversation"
                var buttons = [conversation]
                if hasRoute {
                    let navigate = CPButton(image: UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill")!) { [weak self, weak templateApplicationScene] _ in
                        guard let self, let templateApplicationScene, self.scene === templateApplicationScene else { return }
                        self.navigate()
                    }
                    navigate.title = "Navigate"
                    buttons.insert(navigate, at: 0)
                }
                state.actionButtons = buttons
                return state
            }
        }
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        voice = template
        interfaceController.setRootTemplate(template, animated: false) { [weak self, weak templateApplicationScene] success, error in
            guard let self, let templateApplicationScene, self.scene === templateApplicationScene else { return }
            self.ready = success
            if !success { self.runtime.chat.notice = error?.localizedDescription ?? "CarPlay could not open Haru." }
            if success, self.drive.automaticStartAvailable { self.start() }
        }
        update()
        observe()
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
        PhoneTools.shared.carPlayDirections = nil
        PhoneTools.shared.activity(carPlayActive: false)
        runtime.chat.inCarPlay = false
        runtime.chat.onCarPlayInterruption = nil
        Audio.carPlay = false
        scene = nil
        voice = nil
        states = []
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
            if !self.drive.briefed {
                self.drive.didBrief()
                self.update()
                _ = await chat.drivingBriefing()
            }
            guard !Task.isCancelled, self.drive.visible, self.startupID == epoch else { return }
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
        guard let voice else { return }
        let chat = runtime.chat
        let identifier: String
        if chat.notice != nil, !drive.running { identifier = failureState ?? "unavailable" }
        else if opening { identifier = chat.busy || chat.audio.speaking ? "briefing" : "connecting" }
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
        voice.activateVoiceControlState(withIdentifier: identifier + (hasRoute ? "_route" : ""))
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
            guard let self else { return }
            if !accepted { self.runtime.chat.notice = "Maps could not open. Try again when parked." }
            self.update()
        }
    }
}
