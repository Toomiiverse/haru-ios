import SwiftUI

extension PushPrefs {
    static let blank = PushPrefs(random: true, events: true, system: true, weather: true,
                                 quietFrom: "23:00", quietTo: "08:00", upBy: "09:00")
}

struct MoreView: View {
    @Environment(Session.self) private var session
    @Environment(Locator.self) private var locator
    @State private var prefs = PushPrefs.blank
    @State private var prefsLoaded = false
    @State private var placeName = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                notifications
                whereabouts
                Section("Her memory") {
                    NavigationLink("What she remembers") { MemoryView() }
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
                Button("OK") { problem = nil; locator.problem = nil }
            } message: {
                Text(problem ?? locator.problem ?? "")
            }
        }
        .task { await load() }
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { problem != nil || locator.problem != nil },
                set: { if !$0 { problem = nil; locator.problem = nil } })
    }

    private func load() async {
        await locator.load()
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

    // MARK: Notifications

    private var notifications: some View {
        Section {
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
            Button("Allow notifications on this phone") {
                Task { _ = await Refresh.askPermission() }
            }
        } header: {
            Text("When she speaks first")
        } footer: {
            Text("These are her rules for pestering you, shared with the desktop. On this phone she can only get a word in when iOS wakes the app in the background, so expect her while the app is open and now and then otherwise.")
        }
        .disabled(!prefsLoaded)
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

    private var whereabouts: some View {
        Section {
            Toggle("Let her know where you are", isOn: Binding(
                get: { locator.state?.enabled ?? false },
                set: { on in Task { await locator.setEnabled(on) } }
            ))
            .disabled(locator.state == nil)
            if let state = locator.state, state.enabled {
                if let last = state.last {
                    LabeledContent("Last fix", value: "within \(Int(last.accuracy)) m, on \(last.net)")
                } else {
                    Text("No fix sent yet.").foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Name this place (home, work…)", text: $placeName)
                    Button("Name") {
                        let name = placeName.trimmingCharacters(in: .whitespaces)
                        placeName = ""
                        Task { await locator.name(name) }
                    }
                    .disabled(placeName.trimmingCharacters(in: .whitespaces).isEmpty || state.last == nil)
                }
                Button("Look up what this place is called") {
                    Task { if let found = await locator.lookUp(), !found.isEmpty { placeName = found } }
                }
                .disabled(state.last == nil)
                ForEach(state.places) { place in
                    LabeledContent(place.name, value: "\(Int(place.radiusM)) m")
                        .swipeActions {
                            Button("Forget", role: .destructive) { Task { await locator.forget(place.name) } }
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
