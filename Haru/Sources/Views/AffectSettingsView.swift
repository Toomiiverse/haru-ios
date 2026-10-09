import SwiftUI

struct AffectSettingsView: View {
    @Environment(Session.self) private var session
    @State private var saved: AffectSettings?
    @State private var draft: [String: Bool] = [:]
    @State private var busy = false
    @State private var needsRefresh = false
    @State private var problem: String?
    @State private var confirmed = false

    var body: some View {
        Form {
            if let saved {
                Section("Current expression") {
                    Label(saved.current.emotion.capitalized,
                          systemImage: MoodLook.symbol(for: saved.current.emotion))
                    LabeledContent("Response", value: saved.current.disposition.capitalized)
                    if !saved.enabled {
                        Text("Emotion reactions are currently unavailable on the server.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !saved.current.episodes.isEmpty {
                    Section("Current feelings") {
                        ForEach(Array(saved.current.episodes.enumerated()), id: \.offset) { _, episode in
                            LabeledContent(episode.emotion.capitalized,
                                           value: episode.intensity.formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                }
                Section {
                    ForEach(saved.controls) { control in
                        if draft[control.key] != nil {
                            Toggle(isOn: Binding(
                                get: { draft[control.key] ?? false },
                                set: { draft[control.key] = $0; confirmed = false }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(control.label)
                                    Text(control.description).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Reactions")
                } footer: {
                    Text("Changes take effect after Save confirms them. Haru’s personality and voice stay the same.")
                }
                .disabled(busy || needsRefresh || !saved.enabled)
                Section {
                    Button("Save changes") { Task { await save() } }
                        .disabled(busy || needsRefresh || !saved.enabled || draft == saved.preferences)
                    if confirmed {
                        Label("Saved", systemImage: "checkmark.circle")
                            .accessibilityLabel("Changes saved")
                    }
                }
            } else if busy {
                ProgressView("Loading feelings…")
            }
            if let problem {
                Section("Needs attention") { Text(problem) }
            }
            Section {
                Button(needsRefresh ? "Refresh settings before trying again" : "Refresh") {
                    Task { await refresh() }
                }.disabled(busy)
                if saved != nil && busy { ProgressView() }
            }
        }
        .navigationTitle("Feelings and reactions")
        .task(id: session.baseURLString) { await refresh() }
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        let address = session.baseURLString
        busy = true
        confirmed = false
        defer { busy = false }
        do {
            let value: AffectSettings = try await session.client.get("/api/affect/settings")
            guard address == session.baseURLString else { return }
            saved = value
            draft = value.preferences
            needsRefresh = false
            problem = nil
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            needsRefresh = true
            problem = "Could not refresh settings. \(error.localizedDescription)"
        }
    }

    @MainActor private func save() async {
        guard !busy, !needsRefresh, let saved else { return }
        let address = session.baseURLString
        busy = true
        confirmed = false
        defer { busy = false }
        do {
            let value = try await session.client.saveAffectSettings(
                AffectSettingsSave(expectedRevision: saved.revision, preferences: draft))
            guard address == session.baseURLString else { return }
            self.saved = value
            draft = value.preferences
            confirmed = true
            problem = nil
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            // An uncertain response is not permission to repeat a write.
            needsRefresh = true
            problem = "Save was not confirmed. Refresh to see the settings Haru has now before trying again."
        }
    }
}
