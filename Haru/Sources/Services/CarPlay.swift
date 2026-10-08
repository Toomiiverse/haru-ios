import AVFoundation
import CarPlay
import MapKit
import Observation

/// Both scenes use HaruRuntime's conversation; connecting a car never creates a second microphone engine.
@available(iOS 26.4, *)
@MainActor final class HaruCarPlayScene: NSObject, CPTemplateApplicationSceneDelegate {
    private weak var scene: CPTemplateApplicationScene?
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
        drive.connect()
        runtime.chat.inCarPlay = true
        runtime.chat.onCarPlayInterruption = { [weak self] in self?.stop() }
        Audio.carPlay = true
        let labels = [("ready", "Talk to Haru", "mic.fill"),
                      ("connecting", "Connecting", "antenna.radiowaves.left.and.right"),
                      ("briefing", "Your drive briefing", "waveform"),
                      ("listening", "Listening", "mic.fill"),
                      ("thinking", "Thinking", "ellipsis"),
                      ("speaking", "Speaking", "waveform"),
                      ("unavailable", "Haru is unavailable", "exclamationmark.circle")]
        states = labels.map { CPVoiceControlState(identifier: $0.0, titleVariants: [$0.1],
                                                 image: UIImage(systemName: $0.2), repeats: false) }
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        voice = template
        interfaceController.setRootTemplate(template, animated: false) { [weak self] success, error in
            guard let self else { return }
            self.ready = success
            if !success { self.runtime.chat.notice = error?.localizedDescription ?? "CarPlay could not open Haru." }
            if success, self.drive.automaticStartAvailable { self.start() }
        }
        update()
        observe()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        drive.activate()
        PhoneTools.shared.activity(carPlayActive: true)
        PhoneTools.shared.carPlayDirections = { [weak self] destination, mode, expires in
            guard let self else { throw PhoneTools.Failure("ios_carplay_disconnected") }
            return try await self.prepareTrip(destination: destination, mode: mode, expires: expires)
        }
        if ready, drive.automaticStartAvailable { start() }
        else { update() }
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
        if UIApplication.shared.applicationState == .active {
            Task { await runtime.chat.standbyOnActive() }
        }
    }

    private func start() {
        guard ready, drive.begin() else { return }
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
                self.runtime.chat.notice = "Haru took too long to connect. Tap Talk to retry."
            }
            defer {
                deadline.cancel()
                if self.startupID == epoch { self.opening = false; self.update() }
            }
            let chat = self.runtime.chat
            await chat.setStandby(false, persist: false)
            guard !Task.isCancelled else { return }
            guard !chat.busy else {
                chat.notice = "Finish the current reply, then tap Talk."
                self.drive.stop()
                return
            }
            chat.stopDrivingAudio()
            await self.runtime.session.check()
            guard !Task.isCancelled, self.drive.visible, self.startupID == epoch else { return }
            guard self.runtime.session.signedIn == true else {
                chat.notice = "Haru is unavailable. Check your connection and account when parked."
                self.drive.stop()
                return
            }
            // The permission is set up on the phone before driving, never requested on the car display.
            guard AVAudioApplication.shared.recordPermission == .granted else {
                chat.notice = "Microphone access must be set up before driving."
                self.drive.stop()
                return
            }
            if !self.drive.briefed {
                self.drive.didBrief()
                self.update()
                _ = await chat.drivingBriefing()
            }
            guard !Task.isCancelled, self.drive.visible, self.startupID == epoch else { return }
            await chat.holdMic()
            if chat.call == nil { self.drive.stop(); chat.audio.releaseSession() }
        }
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
                if self.runtime.session.signedIn == false, self.drive.running { self.stop() }
                self.update()
                self.observe()
            }
        }
    }

    private func update() {
        guard let voice else { return }
        let chat = runtime.chat
        let identifier: String
        if chat.notice != nil, !drive.running { identifier = "unavailable" }
        else if opening { identifier = chat.busy || chat.audio.speaking ? "briefing" : "connecting" }
        else if !drive.running { identifier = "ready" }
        else {
            switch chat.callState {
            case .off: identifier = "ready"
            case .connecting: identifier = "connecting"
            case .listening: identifier = "listening"
            case .thinking: identifier = "thinking"
            case .speaking: identifier = "speaking"
            }
        }
        let conversation = CPButton(image: UIImage(systemName: drive.running ? "stop.fill" : "mic.fill")!) { [weak self] _ in
            guard let self else { return }
            if self.drive.running { self.stop() } else { self.start() }
        }
        conversation.title = drive.running ? "End conversation" : "Talk"
        var buttons = [conversation]
        if let route, route.expires > Date() {
            let navigate = CPButton(image: UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill")!) { [weak self] _ in
                self?.navigate()
            }
            navigate.title = "Navigate"
            buttons.insert(navigate, at: 0)
        }
        for state in states { state.actionButtons = buttons }
        voice.activateVoiceControlState(withIdentifier: identifier)
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
