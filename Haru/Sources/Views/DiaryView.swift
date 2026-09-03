import SwiftUI

/// Her diary, newest first: GET /api/diary.
struct DiaryView: View {
    @Environment(Session.self) private var session
    @State private var entries: [DiaryEntry] = []
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if loaded && entries.isEmpty {
                    Text("She has not written anything yet.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(entry.day).font(.footnote).foregroundStyle(.secondary)
                                Text(entry.title).font(.title2).bold()
                                Text(entry.text).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.day).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Her diary")
            .refreshable { await load() }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let page: DiaryPage = try await session.client.get("/api/diary")
            entries = page.entries
            problem = nil
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }
}
