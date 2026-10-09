import SwiftUI

/// Relationship and agenda from status; current feelings from Core’s affect snapshot.
struct StatusView: View {
    @Environment(Session.self) private var session
    @State private var standing: Standing?
    @State private var problem: String?
    @State private var affect = AffectStatus()
    @State private var request = UUID()
    @State private var standingAddress: String?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            List {
                if let s = standing {
                    Section {
                        HStack(spacing: 14) {
                            let emotion = s.asleep == true ? "sleepy" : affect.snapshot?.current.emotion ?? s.emotion
                            Image(systemName: MoodLook.symbol(for: emotion))
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(MoodLook.tint(for: emotion))
                                .frame(width: 72, height: 72)
                                .background(MoodLook.tint(for: emotion).opacity(0.15), in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.asleep == true ? "Asleep" : emotion.capitalized).font(.headline)
                                if s.asleep == true {
                                    Text("She will answer when she wakes.").font(.subheadline).foregroundStyle(.secondary)
                                } else if let current = affect.snapshot?.current {
                                    Text(current.responseDescription).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text("\(Int(s.daysTalked)) days talked, \(Int(s.knownDays)) known")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if let m = s.minutesSinceSpoke {
                                    Text("You last spoke \(Clock.ago(minutes: m)).")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section("Bond") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(s.bond.title).bold()
                                Spacer()
                                Text("level \(Int(s.bond.level)) of \(Int(s.bond.of))").foregroundStyle(.secondary)
                            }
                            ProgressView(value: min(max(s.bond.level, 0), s.bond.of), total: max(s.bond.of, 1))
                            Text(s.bond.note).font(.footnote).foregroundStyle(.secondary)
                            if s.bond.toNext > 0 {
                                Text("\(Int(s.bond.toNext)) to the next.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let affection = s.meters.first(where: { $0.label == "Affection" }) {
                            MeterRow(meter: affection).tint(.pink)
                        }
                    }

                    if let snapshot = affect.snapshot {
                        MoodStatusSections(snapshot: snapshot)
                    } else {
                        Section("Current feelings") {
                            if let problem = affect.problem {
                                Text(problem).foregroundStyle(.secondary)
                                Button("Retry") { Task { await loadAffect() } }
                            } else {
                                ProgressView("Loading feelings…")
                            }
                        }
                    }

                    Section {
                        NavigationLink("Feelings and reactions", destination: AffectSettingsView())
                    }
                    if let problem {
                        Section { Text(problem).foregroundStyle(.secondary) }
                    }

                    if !s.waiting.isEmpty {
                        Section("Waiting on you") {
                            ForEach(s.waiting) { item in WaitingRow(item: item) { await tickOff(item.id) } }
                        }
                    }
                    if !s.stale.isEmpty {
                        Section("Given up asking about") {
                            ForEach(s.stale) { item in WaitingRow(item: item) { await tickOff(item.id) } }
                        }
                    }
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Where you stand")
            .refreshable { await load() }
        }
        .task(id: session.baseURLString) { await load() }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await load() } }
        }
    }

    private func load() async {
        async let relationship: Void = loadStanding()
        async let feelings: Void = loadAffect()
        _ = await (relationship, feelings)
    }

    private func loadStanding() async {
        let token = UUID()
        request = token
        let address = session.baseURLString
        if standingAddress != address {
            standing = nil
            problem = nil
            standingAddress = address
        }
        do {
            let value: Standing = try await session.client.get("/api/status")
            guard request == token, address == session.baseURLString, !Task.isCancelled else { return }
            standing = value
            problem = nil
        } catch {
            guard request == token, address == session.baseURLString, !Task.isCancelled else { return }
            if case HaruError.signedOut = error { session.signedIn = false }
            problem = "Relationship status couldn’t be refreshed. Pull down to try again."
        }
    }

    private func loadAffect() async {
        do { try await affect.refresh(client: session.client) }
        catch HaruError.signedOut { session.signedIn = false }
        catch { /* The read state supplies a visible retry. */ }
    }

    private func tickOff(_ id: String) async {
        let _: AgendaPage? = try? await session.client.post("/api/agenda/done", ["id": .string(id)])
        await load()
        await Reminders.shared.sync(force: true)
    }
}

struct MeterRow: View {
    let meter: Meter
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meter.label)
                Spacer()
                Text("\(Int(meter.value.rounded()))").foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: min(max(meter.value, 0), 100), total: 100)
            if !meter.note.isEmpty {
                Text(meter.note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct WaitingRow: View {
    let item: WaitingItem
    let done: () async -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.when).font(.footnote).foregroundStyle(item.late ? .red : .secondary)
            }
            Spacer()
            Button { Task { await done() } } label: { Image(systemName: "checkmark.circle") }
                .buttonStyle(.borderless)
        }
        .swipeActions {
            Button("Done") { Task { await done() } }.tint(.green)
        }
    }
}
