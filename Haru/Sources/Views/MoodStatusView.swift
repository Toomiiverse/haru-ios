import SwiftUI

/// The same Core snapshot is presented in Status, the quick menu and reaction settings.
struct FeelingRow: View {
    let episode: AffectSettings.Current.Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text(episode.intensity.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(.secondary).monospacedDigit()
            } label: {
                Label(episode.emotion.capitalized, systemImage: MoodLook.symbol(for: episode.emotion))
            }
            ProgressView(value: min(max(episode.intensity, 0), 1))
                .tint(MoodLook.tint(for: episode.emotion))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct MoodDimensionRow: View {
    let dimension: MoodDimension
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(dimension.title, value: value.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
            ProgressView(value: min(max(value, 0), 1)).tint(tint)
            Text(dimension.note).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch dimension.key {
        case "pleasantness": return .pink
        case "activation": return .orange
        case "tension": return .purple
        case "energy": return .yellow
        case "sleepiness": return .indigo
        default: return .accentColor
        }
    }
}

struct MoodStatusSections: View {
    let snapshot: AffectSettings

    var body: some View {
        let feelings = snapshot.current.displayFeelings
        Section {
            if !snapshot.enabled {
                Text("Emotion reactions are currently unavailable.").foregroundStyle(.secondary)
            } else if feelings.isEmpty {
                Text("No strong feelings right now.").foregroundStyle(.secondary)
            } else {
                ForEach(feelings, id: \.emotion) { episode in
                    FeelingRow(episode: episode)
                }
            }
        } header: {
            Text("Current feelings")
        } footer: {
            if snapshot.enabled && !feelings.isEmpty {
                Text("Each feeling appears once, at its strongest current intensity.")
            }
        }
        if let mood = snapshot.current.mood {
            Section("Underlying mood") {
                ForEach(MoodDimension.all) { dimension in
                    if let value = mood[dimension.key] {
                        MoodDimensionRow(dimension: dimension, value: value)
                    }
                }
            }
        }
    }
}

struct MoodStatusSummary: View {
    @Environment(Session.self) private var session
    @State private var status = AffectStatus()
    let asleep: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = status.snapshot {
                let feelings = snapshot.current.displayFeelings
                let emotion = asleep ? "sleepy" : snapshot.current.emotion
                Label(asleep ? "Asleep" : emotion.capitalized, systemImage: MoodLook.symbol(for: emotion))
                    .font(.headline).foregroundStyle(MoodLook.tint(for: emotion))
                Text(asleep ? "She will answer when she wakes." : snapshot.current.responseDescription)
                    .font(.subheadline).foregroundStyle(.secondary)
                if !snapshot.enabled {
                    Text("Emotion reactions are currently unavailable.").font(.caption).foregroundStyle(.secondary)
                } else if feelings.isEmpty {
                    Text("No strong feelings right now.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(feelings.prefix(3)), id: \.emotion) { episode in
                        FeelingRow(episode: episode).font(.subheadline)
                    }
                    if feelings.count > 3 {
                        Text("More feelings in full status").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let problem = status.problem {
                Text(problem).font(.subheadline).foregroundStyle(.secondary)
                Button("Retry") { Task { await refresh() } }
            } else {
                ProgressView("Loading feelings…")
            }
        }
        .task(id: session.baseURLString) { await refresh() }
    }

    private func refresh() async {
        do { try await status.refresh(client: session.client) }
        catch HaruError.signedOut { session.signedIn = false }
        catch { /* The read state supplies a visible retry. */ }
    }
}
