// What was wrong with a reply of hers, in his words.
//
// Deliberately not a rating. A thumb is something she is told: it moves her
// mood, it is quoted into her next prompt, and she answers it back. This is
// the other kind of note — the one written about her while she is still being
// tuned — and she never sees it. It goes to a log on the desk, one line of
// JSON and one line on the day's page, for him to read at the end of a day or
// hand to an agent.
//
// Two fields rather than one because the second is worth more than the first:
// "too long" says what to avoid, but the reply he would rather have had is a
// pair — this prompt, that answer — and a day of those is something to tune on.

import SwiftUI

struct TuneSheet: View {
    let entry: Entry
    @Environment(ChatStore.self) private var chat
    @Environment(\.dismiss) private var dismiss
    @State private var wrong = ""
    @State private var rather = ""
    @State private var sending = false

    private var ready: Bool {
        !sending && !(wrong.trimmed.isEmpty && rather.trimmed.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("She said") {
                    Text(entry.text).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Too long, wrong tone, made something up…", text: $wrong, axis: .vertical).lineLimit(1...4)
                } header: {
                    Text("What was wrong")
                }
                Section {
                    TextField("The reply you wanted", text: $rather, axis: .vertical).lineLimit(1...10)
                } header: {
                    Text("What you'd rather")
                } footer: {
                    Text("Both optional, either is enough. She never sees this — it goes to the tuning log for you to read later.")
                }
            }
            .navigationTitle("What was wrong")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log it") {
                        sending = true
                        Task {
                            _ = await chat.tune(entry, wrong: wrong.trimmed, rather: rather.trimmed)
                            dismiss()
                        }
                    }
                    .disabled(!ready)
                }
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
