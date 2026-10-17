import SwiftUI

/// Coding mode: the coder's steps as cards (Codex / Claude Code-style), his prompts, its questions with
/// Allow / Deny, a stop button while it works, the diff, and earlier sessions. Commands: /new /stop /diff /sessions /model /cd /exit.
struct CodeView: View {
    @Environment(Session.self) private var session
    @Environment(Navigator.self) private var nav
    var store: CodeStore
    @State private var draft = ""
    @State private var showDiff = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.folder == nil { projects } else { transcript }
            composer
        }
        // A folder asked for elsewhere (/code in the chat, a link, a push) is taken here, before the session loads.
        .task { store.pendingFolder = takeFolder(); await store.open(session.client) }
        .onChange(of: nav.wantsCode) { _, folder in
            guard folder != nil else { return }
            store.pendingFolder = takeFolder()
            Task { await store.open(session.client) }
        }
        .onChange(of: store.exitRequested) { _, now in if now { store.exitRequested = false; nav.tab = .chat } }
        // Leaving the tab: the stream closes and Haru hears once what was worked on.
        .onDisappear { let client = session.client; Task { await store.leave(client) } }
        .onChange(of: store.diff == nil) { _, none in if !none { showDiff = true } }
        .sheet(isPresented: $showDiff, onDismiss: { store.diff = nil }) { CodeDiffSheet(diff: store.diff) }
        .sheet(isPresented: Binding(get: { store.showRecent }, set: { store.showRecent = $0 })) { CodeRecentSheet(store: store) }
        .alert("Coding mode", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } })) {
            Button("OK") { store.problem = nil }
        } message: { Text(store.problem ?? "") }
    }

    private func takeFolder() -> String? {
        defer { nav.wantsCode = nil }
        return nav.wantsCode
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.projects, id: \.self) { name in
                    Button(name) { Task { await store.start(name, session.client) } }
                }
            } label: {
                Label(store.folder ?? "Project", systemImage: "folder").lineLimit(1)
            }
            .accessibilityLabel("Project folder: \(store.folder ?? "none")")
            Menu {
                ForEach(store.models, id: \.self) { m in
                    Button { Task { await store.setModel(m.id, session.client) } } label: {
                        if m.id == store.model { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                    }
                }
            } label: {
                Label(store.modelName, systemImage: "cpu").lineLimit(1)
            }
            .accessibilityLabel("Model: \(store.modelName)")
            Spacer()
            if let spent = store.spent {
                Text(String(format: "$%.2f / $%.0f", spent.today, spent.cap))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel(String(format: "Spent %.2f of %.0f dollars today", spent.today, spent.cap))
            }
            Button { store.showRecent = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .accessibilityLabel("Recent sessions")
            Button { Task { await store.loadDiff(session.client) } } label: { Image(systemName: "plusminus") }
                .disabled(store.folder == nil).accessibilityLabel("Show changes")
            Button { if let folder = store.folder { Task { await store.start(folder, session.client) } } } label: { Image(systemName: "square.and.pencil") }
                .disabled(store.folder == nil || store.busy).accessibilityLabel("New session")
            Button { Task { await store.start("", session.client) } } label: { Image(systemName: "plus") }
                .disabled(store.busy).accessibilityLabel("New quick session")
                .accessibilityHint("Starts a session in the quick-code scratch folder")
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var projects: some View {
        List {
            Section {
                Button { Task { await store.start("", session.client) } } label: { Label("Quick session", systemImage: "plus") }
                Button { store.showRecent = true } label: { Label("Recent sessions", systemImage: "clock.arrow.circlepath") }
            } footer: {
                Text("For small changes and try-outs: a scratch folder, quick-code, kept in git on the server.")
            }
            Section("Pick a project") {
                ForEach(store.projects, id: \.self) { name in
                    Button { Task { await store.start(name, session.client) } } label: { Label(name, systemImage: "folder") }
                }
            }
            Section {
                Text("The coder works in a git repository in your home folder. It edits files freely; any other command waits for you to allow it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.items.isEmpty {
                        Text("Tell the coder what to do in \(store.folder ?? "this project").")
                            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    ForEach(store.items) { item in
                        CodeCard(item: item) { decision in Task { await store.answer(item.id, decision, session.client) } }
                            .id(item.kind + item.id)
                    }
                    if store.running {
                        HStack(spacing: 8) { ProgressView(); Text("Working…").font(.footnote).foregroundStyle(.secondary) }
                            .id("working")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.items.count) { _, _ in
                withAnimation { proxy.scrollTo(store.running ? "working" : (store.items.last.map { $0.kind + $0.id } ?? ""), anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Terminal: a leading "!" runs the line as a command in the project folder, like Claude Code.
            Button { draft = terminalCommand(draft) != nil ? String(draft.drop(while: { $0 == " " }).dropFirst()) : "!" + draft; typing = true } label: {
                Image(systemName: "terminal").font(.title3).foregroundStyle(terminalCommand(draft) != nil ? Color.orange : Color.secondary)
            }
            .padding(.bottom, 6)
            .disabled(store.folder == nil)
            .accessibilityLabel(terminalCommand(draft) != nil ? "Terminal on: the line runs as a command" : "Run a terminal command")
            TextField(store.folder == nil ? "/code <folder>" : "Tell the coder…  (!cmd runs a command)", text: $draft, axis: .vertical)
                .lineLimit(1...8)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange, lineWidth: terminalCommand(draft) != nil ? 1.5 : 0))
                .focused($typing)
            if store.running && draft.isEmpty {
                Button { Task { await store.stop(session.client) } } label: { Image(systemName: "stop.circle.fill").font(.title) }
                    .tint(.red).accessibilityLabel("Stop the coder")
            } else {
                Button {
                    let text = draft
                    draft = ""
                    Task { if !(await store.send(text, session.client)) && draft.isEmpty { draft = text } }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
                    .accessibilityLabel("Send to the coder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// One card: his prompt, the coder's words, a tool step, a question, or an error.
private struct CodeCard: View {
    let item: CodeItem
    let answer: (String) -> Void
    @State private var open = false

    var body: some View {
        switch item.kind {
        case "you":
            HStack { Spacer(minLength: 40)
                Text(item.text ?? "").padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
        case "said": CodeText(text: item.text ?? "")
        case "tool": tool
        case "ask": ask
        default:
            Label(item.text ?? "Something went wrong.", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.red)
        }
    }

    private var icon: String {
        switch item.name ?? "" {
        case "read": return "doc.text"
        case "edit", "write", "patch": return "pencil"
        case "shell", "bash", "terminal": return "terminal"
        case "grep", "glob", "list": return "magnifyingglass"
        case "webfetch", "websearch": return "globe"
        case "todowrite": return "checklist"
        default: return "wrench"
        }
    }

    /// A shell step that exited non-zero is marked failed, even though the tool itself ran.
    private var exitedClean: Bool { (item.exit ?? 0) == 0 }

    private var tool: some View {
        let hasBody = !(item.output ?? "").isEmpty || !(item.patch ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            Button { if hasBody { withAnimation { open.toggle() } } } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
                    Text(item.name ?? "tool").font(.footnote.weight(.semibold))
                    Text(item.title ?? "").font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    switch item.status ?? "" {
                    case "done": Image(systemName: exitedClean ? "checkmark" : "xmark").foregroundStyle(exitedClean ? Color.green : Color.red)
                    case "failed": Image(systemName: "xmark").foregroundStyle(.red)
                    default: ProgressView().controlSize(.mini)
                    }
                    if hasBody { Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.name ?? "tool") \(item.title ?? ""), \(item.status ?? "running")")
            if open {
                if let patch = item.patch, !patch.isEmpty { PatchText(patch: patch) }
                else { ScrollView(.horizontal) { Text(item.output ?? "").font(.caption.monospaced()).textSelection(.enabled).padding(8) } }
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The coder wants to run", systemImage: "hand.raised").font(.footnote.weight(.semibold))
            ForEach(item.resources ?? [], id: \.self) { r in
                Text(r).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let reply = item.reply {
                Text(reply == "reject" ? "Denied" : reply == "always" ? "Always allowed" : "Allowed once").font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Allow once") { answer("once") }.buttonStyle(.borderedProminent)
                    Button("Always") { answer("always") }.buttonStyle(.bordered)
                    Button("Deny", role: .destructive) { answer("reject") }.buttonStyle(.bordered)
                }
                .font(.footnote)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The coder's words: inline markdown, with fenced code blocks in monospace.
private struct CodeText: View {
    let text: String
    var body: some View {
        let parts = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { n, part in
                if n % 2 == 1 {
                    let code = part.drop(while: { $0 != "\n" }).dropFirst()   // the language name after ```
                    ScrollView(.horizontal) { Text(String(code.isEmpty ? Substring(part) : code)).font(.caption.monospaced()).textSelection(.enabled).padding(8) }
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(Self.inline(part.trimmingCharacters(in: .newlines))).textSelection(.enabled)
                }
            }
        }
    }
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// A unified diff, added lines green and removed lines red.
struct PatchText: View {
    let patch: String
    var body: some View {
        let lines = patch.components(separatedBy: "\n").filter { !$0.hasPrefix("Index:") && !$0.hasPrefix("====") && !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ") }
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.caption.monospaced())
                        .foregroundStyle(line.hasPrefix("@@") ? Color.blue : line.hasPrefix("+++") || line.hasPrefix("---") ? Color.secondary : line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .textSelection(.enabled)
        }
    }
}

/// /diff: every changed file against the last commit, with its +/− counts, and files git does not track yet.
private struct CodeDiffSheet: View {
    let diff: CodeDiff?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let diff, diff.files.isEmpty && diff.untracked.isEmpty { Text("No changes since the last commit.").foregroundStyle(.secondary) }
                ForEach(diff?.files ?? []) { file in
                    DisclosureGroup {
                        PatchText(patch: file.patch)
                    } label: {
                        HStack {
                            Text(file.file).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("+\(file.additions)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                            Text("−\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                        }
                    }
                }
                if let untracked = diff?.untracked, !untracked.isEmpty {
                    Section("New, not in git yet") { ForEach(untracked, id: \.self) { Text($0).font(.footnote.monospaced()) } }
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// /sessions: his earlier coding sessions, newest first. Tap to continue; swipe to archive or delete.
private struct CodeRecentSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: CodeStore
    @State private var showArchived = false
    @State private var deleting: CodeSessionRow?

    var body: some View {
        NavigationStack {
            List {
                let rows = store.recent.filter { $0.archived == showArchived }
                if rows.isEmpty {
                    Text(showArchived ? "No archived sessions." : "No coding sessions yet.").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Button {
                        Task { await store.resume(row.id, session.client); if store.problem == nil { dismiss() } }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Label(row.folder, systemImage: "folder").font(.subheadline.weight(.semibold))
                                if row.current { Text("open").font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
                                Spacer()
                                if let d = row.updated { Text(d, style: .relative).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(row.task.isEmpty ? "Nothing asked yet" : row.task).font(.footnote).lineLimit(2)
                                .foregroundStyle(row.task.isEmpty ? .secondary : .primary)
                            if let m = row.model { Text(store.models.first { $0.id == m }?.name ?? m).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Continue this session")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = row } label: { Label("Delete", systemImage: "trash") }
                        Button { Task { await store.archive(row.id, !row.archived, session.client) } } label: {
                            Label(row.archived ? "Unarchive" : "Archive", systemImage: row.archived ? "tray.and.arrow.up" : "archivebox")
                        }
                        .tint(.indigo)
                    }
                }
            }
            .navigationTitle(showArchived ? "Archived sessions" : "Recent sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(showArchived ? "Recent" : "Archived") { showArchived.toggle() }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await store.loadRecent(session.client) }
            .task { await store.loadRecent(session.client) }
            .confirmationDialog("Delete this session?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { row in
                Button("Delete", role: .destructive) { Task { await store.delete(row.id, session.client) } }
            } message: { _ in Text("Its conversation with the coder is removed from the server. Files it changed stay as they are.") }
        }
    }
}
