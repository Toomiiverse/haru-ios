import SwiftUI

/// Her own things — nights out, likes, wants: GET /api/her.
struct HerView: View {
    @Environment(Session.self) private var session
    @State private var her: Her?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        WorldView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Little World")
                                Text("Visit her town, garden and little adventures.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "leaf.fill")
                        }
                    }
                }
                if let her {
                    Section {
                        LabeledContent("Nights out", value: nights(her.nightsOut))
                        LabeledContent("Diary entries", value: diary(her.diary))
                    }
                    if !her.things.isEmpty {
                        Section("Her things") {
                            ForEach(her.things) { thing in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(thing.name).bold()
                                        Spacer()
                                        Text(thing.kind).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Text(thing.stance).font(.subheadline)
                                    Text("Since \(thing.since), \(Int(thing.nights)) night\(Int(thing.nights) == 1 ? "" : "s"). \(thing.because)")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    if let favourite = thing.favourite {
                                        Label(favourite, systemImage: "star").font(.footnote)
                                    }
                                    if let wants = thing.wants {
                                        Label(wants, systemImage: "gift").font(.footnote)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    if !her.likes.isEmpty {
                        Section("Likes") {
                            ForEach(her.likes) { LabeledContent($0.name, value: $0.of) }
                        }
                    }
                    if !her.wants.isEmpty {
                        Section("Wants") {
                            ForEach(her.wants) { LabeledContent($0.wish, value: $0.of) }
                        }
                    }
                    if !her.adventures.isEmpty {
                        Section("Where she has been") {
                            ForEach(her.adventures) { night in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(night.about).bold()
                                        Spacer()
                                        Text(night.day).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Text(night.why).font(.footnote).foregroundStyle(.secondary)
                                    if let note = night.note, !note.isEmpty { Text(note).font(.subheadline) }
                                    ForEach(night.sources ?? [], id: \.self) { source in
                                        if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                                            Link(source, destination: url).font(.footnote).lineLimit(1)
                                        } else {
                                            Text(source).font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Her")
            .refreshable { await load() }
        }
        .task { await load() }
    }

    private func nights(_ n: Her.NightsOut) -> String {
        let count = Int(n.count)
        guard let first = n.first, count > 0 else { return "\(count)" }
        return "\(count), since \(first)"
    }

    private func diary(_ d: Her.Diary) -> String {
        let count = Int(d.entries)
        guard let since = d.since, count > 0 else { return "\(count)" }
        return "\(count), since \(since)"
    }

    private func load() async {
        do {
            her = try await session.client.get("/api/her")
            problem = nil
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            problem = error.localizedDescription
        }
    }
}
