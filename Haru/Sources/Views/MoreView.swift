import SwiftUI

extension PushPrefs {
    static let blank = PushPrefs(random: true, events: true, system: true, weather: true,
                                 quietFrom: "23:00", quietTo: "08:00", upBy: "09:00")
}

struct MoreView: View {
    @Environment(Session.self) private var session
    @Environment(Locator.self) private var locator
    @Environment(ChatStore.self) private var chat
    @Environment(\.scenePhase) private var phase
    @State private var delivery: Delivery?
    @State private var prefs = PushPrefs.blank
    @State private var prefsLoaded = false
    @State private var placeName = ""
    @State private var problem: String?
    @AppStorage("stage.zoom") private var stageZoom = 1.0
    @AppStorage("stage.lift") private var stageLift = 0.0
    @AppStorage("talk.echoCancel") private var echoCancel = true
    @State private var evi: EviStatus?

    var body: some View {
        NavigationStack {
            List {
                herStage
                talking
                notifications
                delivered
                whereabouts
                health
                reminders
                Section("Her memory") {
                    NavigationLink("What she remembers") { MemoryView() }
                }
                Section {
                    NavigationLink("What she mishears") { HearingView() }
                } header: {
                    Text("Her ears")
                } footer: {
                    Text("Long-press one of your own bubbles when she gets a word wrong. She keeps the difference.")
                }
                Section {
                    LabeledContent("Her address", value: session.baseURLString)
                    Button("Sign out", role: .destructive) { Task { await session.signOut() } }
                } header: {
                    Text("This phone")
                } footer: {
                    Text("Signing out forgets this phone on her side too; sign in again to be remembered.")
                }
            }
            .navigationTitle("More")
            .refreshable { await load() }
            .alert("Haru", isPresented: problemShown) {
                Button("OK") { problem = nil; locator.problem = nil; Health.shared.problem = nil; Reminders.shared.problem = nil }
            } message: {
                Text(problem ?? locator.problem ?? Health.shared.problem ?? Reminders.shared.problem ?? "")
            }
        }
        .task { await load() }
        .onChange(of: phase) { _, now in
            // Back from Settings: what iOS does with her may have just changed.
            guard now == .active else { return }
            Task { delivery = await Delivery.current() }
        }
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { problem != nil || locator.problem != nil || Health.shared.problem != nil || Reminders.shared.problem != nil },
                set: { if !$0 { problem = nil; locator.problem = nil; Health.shared.problem = nil; Reminders.shared.problem = nil } })
    }

    private func load() async {
        delivery = await Delivery.current()
        await locator.load()
        await Health.shared.load()
        await Reminders.shared.load()
        evi = try? await session.client.get("/api/evi/status")
        do {
            let info: PushInfo = try await session.client.get("/api/push")
            prefs = info.prefs
            prefsLoaded = true
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Her stage

    private var herStage: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("Zoom \(stageZoom, specifier: "%.2f")×").font(.footnote).foregroundStyle(.secondary)
                Slider(value: $stageZoom, in: 0.5...2, step: 0.05)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Position \(stageLift >= 0 ? "up" : "down") \(abs(stageLift), specifier: "%.2f")").font(.footnote).foregroundStyle(.secondary)
                Slider(value: $stageLift, in: -0.5...0.5, step: 0.01)
            }
            Button("Back to how it was") { stageZoom = 1; stageLift = 0 }
        } header: {
            Text("Her stage")
        } footer: {
            Text("Her face, the same one the phone page shows. Zoom scales it; position moves it up or down.")
        }
    }

    // MARK: Talking

    private var talking: some View {
        Section {
            LabeledContent("Calls", value: callLine)
            Toggle("Standby: “Hey Haru” with the phone locked", isOn: Binding(
                get: { chat.standby },
                set: { on in Task { await chat.setStandby(on) } }
            ))
            if chat.standby {
                LabeledContent("Standby", value: chat.standbyLine)
                LabeledContent("Her ears", value: chat.wakeEngine)
            }
            Toggle("Cancel her echo while listening", isOn: $echoCancel)
            if let take = chat.enrolling {
                LabeledContent("Say “Hey Haru”", value: "take \(take + 1) of \(VoiceGate.takes)")
                Button("Stop") { chat.cancelEnrolment() }
            } else {
                LabeledContent("Your voice", value: chat.voiceKnown ? "\(chat.voiceTakes) takes" + (chat.strangerLine.isEmpty ? "" : " · \(chat.strangerLine)") : "not taught")
                Button(chat.voiceKnown ? "Teach her your voice again" : "Teach her your voice") { Task { await chat.startEnrolment() } }
                if chat.voiceKnown {
                    Toggle("Only my voice wakes her", isOn: Binding(get: { chat.onlyMyVoice }, set: { chat.onlyMyVoice = $0 }))
                    Button("Forget my voice", role: .destructive) { chat.forgetVoice() }
                }
            }
        } header: {
            Text("Talking")
        } footer: {
            Text("Tap the mic and ask: she listens for one question, writes it down and answers as she does a message, in her voice, and the mic closes itself. Hold the mic for a call: she listens, decides when you've finished, lets you talk over her, and answers a sentence at a time. Typed messages get her usual voice either way. Echo cancelling on: she can't hear herself through the speaker; off is best on earphones.\n\nStandby: switch it on here, then lock the phone. She listens on the phone itself for “Hey Haru” — nothing is sent anywhere until she hears it — then chimes and takes a call, and hangs up after 45 seconds of quiet. It uses battery while it is on and shows the microphone light. A phone call or Siri pauses it; open Haru to start it again. On the charger the screen stays awake.\n\nYour voice: tap Teach, say “Hey Haru” six times as you normally would (near, far, quiet), and from then on her name in another voice does not wake her — the check happens on the phone, against those takes. The takes also go to her server, to train a wake word that is yours.\n\nWith standby off: the Call Haru shortcut, given a Vocal Shortcut (“Hey Haru”) under Settings › Accessibility, opens her in a call — after Face ID if the phone is locked.")
        }
    }

    private var callLine: String {
        guard let evi else { return "…" }
        let used = Int(evi.minutesToday ?? 0), cap = Int(evi.cap ?? 0)
        let where_ = evi.engine == "local" ? "at home" : evi.engine == "hume" ? "through Hume" : (evi.engine ?? "")
        if evi.enabled == true { return cap > 0 ? "\(where_), \(used) of \(cap) min today" : where_ }
        switch evi.reason {
        case "off": return "switched off on her server"
        case "not set up": return "not set up on her server"
        case "asleep": return "she is asleep"
        case "cap": return "\(used) of \(cap) min — that's the day"
        default: return "not available"
        }
    }

    // MARK: Her eye on you

    private var health: some View {
        let health = Health.shared
        return Section {
            Toggle("Let her see how you slept", isOn: Binding(
                get: { health.state?.enabled ?? false },
                set: { on in Task { await health.setEnabled(on) } }
            ))
            .disabled(health.state == nil || !Health.available)
            if let s = health.state, s.enabled {
                LabeledContent("Right now", value: bodyLine(s))
            }
        } header: {
            Text("Her eye on you")
        } footer: {
            Text("Last night's sleep and today's steps, from Apple Health, sent to her server as two numbers whenever Health has something new — with the app closed too. She gets one background sentence out of it, enough to notice a short night. Off unless you switch it on; Health asks its own permission.")
        }
    }

    // MARK: Her list, in Reminders

    private var reminders: some View {
        let reminders = Reminders.shared
        return Section {
            Toggle("Keep her list in Reminders", isOn: Binding(
                get: { reminders.enabled },
                set: { on in Task { await reminders.setEnabled(on) } }
            ))
            if reminders.enabled {
                LabeledContent("Last mirrored", value: reminders.lastSyncLine)
            }
        } header: {
            Text("Her list, in Reminders")
        } footer: {
            Text("A list called Haru in Apple Reminders that matches hers, both ways: what you ask her to remind you of shows up there, with an alarm when she was told a time; a reminder you add to that list, or tick off there, reaches her. Events stay in Calendar.")
        }
    }

    private func bodyLine(_ s: BodyState) -> String {
        var bits: [String] = []
        if let m = s.sleepMinutes {
            let h = Int(m) / 60, mm = Int(m) % 60
            bits.append(h == 0 ? "\(mm) m asleep" : mm == 0 ? "\(h) h asleep" : "\(h) h \(mm) m asleep")
        }
        if let steps = s.steps { bits.append("\(Int(steps).formatted()) steps") }
        if bits.isEmpty { return "Nothing sent yet" }
        return bits.joined(separator: " · ") + (s.fresh ? "" : " (old)")
    }

    // MARK: Notifications

    private var notifications: some View {
        Section {
            if prefs.held == true {
                Label("Held by a Focus on this phone", systemImage: "moon.fill")
                    .foregroundStyle(.secondary)
            }
            Toggle("Out of the blue", isOn: pref(\.random))
            Toggle("Things coming up", isOn: pref(\.events))
            Toggle("Her own news", isOn: pref(\.system))
            Toggle("The weather", isOn: pref(\.weather))
            DatePicker("Quiet from", selection: time(\.quietFrom), displayedComponents: .hourAndMinute)
            DatePicker("Quiet until", selection: time(\.quietTo), displayedComponents: .hourAndMinute)
            Toggle("Wake me up", isOn: Binding(
                get: { !prefs.upBy.isEmpty },
                set: { on in update { $0.upBy = on ? "09:00" : "" } }
            ))
            if !prefs.upBy.isEmpty {
                DatePicker("Up by", selection: time(\.upBy), displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("When she speaks first")
        } footer: {
            Text("These are her rules for pestering you, shared with the desktop. She reaches this phone through Apple's push, so expect her whether the app is open or not. A Focus can hold her too: Settings → Focus → the one you want → Add Filter → Haru.")
        }
        .disabled(!prefsLoaded)
    }

    /// What iOS actually does with hers — read from the phone, since the rules
    /// above are only half of it. A quiet delivery, a summary, a denied
    /// permission: this is where "why was that one silent" gets its answer.
    private var delivered: some View {
        Section {
            if let delivery {
                VStack(alignment: .leading, spacing: 4) {
                    Text(delivery.headline)
                    Text(delivery.details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if delivery.status == .notAsked {
                    Button("Allow notifications") {
                        Task {
                            _ = await Refresh.askPermission()
                            self.delivery = await Delivery.current()
                        }
                    }
                } else {
                    Button("Open her page in Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("How this phone shows her")
        } footer: {
            Text("Read from the phone's own settings. “Quietly” means Notification Center only, with no banner and no sound; pick “Deliver Prominently” on one of hers, or switch banners and sound back on in Settings. A Focus mode silences her too, and iOS does not tell apps about that.")
        }
    }

    private func pref(_ key: WritableKeyPath<PushPrefs, Bool>) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }

    private func time(_ key: WritableKeyPath<PushPrefs, String>) -> Binding<Date> {
        Binding(get: { Clock.date(from: prefs[keyPath: key]) },
                set: { date in update { $0[keyPath: key] = Clock.hhmm(date) } })
    }

    private func update(_ change: (inout PushPrefs) -> Void) {
        var next = prefs
        change(&next)
        guard next != prefs else { return }
        prefs = next
        Task { await save(next) }
    }

    private func save(_ next: PushPrefs) async {
        do {
            let page: PushPrefsPage = try await session.client.post("/api/push/prefs", next.body)
            prefs = page.prefs
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Whereabouts

    private func whereLine(_ state: Whereabouts) -> String {
        guard state.fresh || locator.reported else { return "No fix sent yet." }
        let place = state.at.map { "at \($0)" } ?? "somewhere unnamed"
        let net = state.net.map { ", on \($0)" } ?? ""
        return place + net
    }

    private var whereabouts: some View {
        Section {
            Toggle("Let her know where you are", isOn: Binding(
                get: { locator.state?.enabled ?? false },
                set: { on in Task { await locator.setEnabled(on) } }
            ))
            .disabled(locator.state == nil)
            if let state = locator.state, state.enabled {
                LabeledContent("Right now", value: whereLine(state))
                HStack {
                    TextField("Name this place (home, work…)", text: $placeName)
                    Button("Name") {
                        let name = placeName.trimmingCharacters(in: .whitespaces)
                        placeName = ""
                        Task { await locator.name(name) }
                    }
                    .disabled(placeName.trimmingCharacters(in: .whitespaces).isEmpty || !(locator.reported || state.fresh))
                }
                Button("Look up what this place is called") {
                    Task { if let found = await locator.lookUp(), !found.isEmpty { placeName = found } }
                }
                .disabled(!(locator.reported || state.fresh))
                ForEach(state.places, id: \.self) { place in
                    Text(place)
                        .swipeActions {
                            Button("Forget", role: .destructive) { Task { await locator.forget(place) } }
                        }
                }
            }
        } header: {
            Text("Where you are")
        } footer: {
            Text("Off unless you switch it on. Only while the app is open. Naming a place \"home\" lets her say how far from it you are.")
        }
    }
}

struct MemoryView: View {
    @Environment(Session.self) private var session
    @State private var memories: [String] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && memories.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(memories.enumerated()), id: \.offset) { _, line in
                Text(line).textSelection(.enabled)
            }
        }
        .navigationTitle("What she remembers")
        .task {
            if let page: MemoryPage = try? await session.client.get("/api/memory") { memories = page.memories }
            loaded = true
        }
    }
}
