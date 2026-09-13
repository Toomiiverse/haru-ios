import SwiftUI

/// Where you stand with her: GET /api/status, with the agenda's tick-off.
struct StatusView: View {
    @Environment(Session.self) private var session
    @State private var standing: Standing?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                if let s = standing {
                    Section {
                        HStack(spacing: 14) {
                            PortraitView().frame(width: 72, height: 72)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.mood).font(.headline)
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
                    }

                    Section("How she is") {
                        ForEach(s.meters) { MeterRow(meter: $0) }
                        MeterRow(meter: s.patience)
                    }

                    Section("Grudge") {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: min(max(s.grudge.value, 0), s.grudge.of), total: max(s.grudge.of, 1)).tint(.red)
                            Text(s.grudge.note).font(.footnote).foregroundStyle(.secondary)
                        }
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
        .task { await load() }
    }

    private func load() async {
        do {
            standing = try await session.client.get("/api/status")
            problem = nil
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            problem = error.localizedDescription
        }
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
