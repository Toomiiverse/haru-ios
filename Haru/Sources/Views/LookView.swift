import SwiftUI

/// What she looks like in the pictures she makes: her tags, edited here and
/// drawn by the image server beside her (ComfyUI's haru_look.py, port 8188 on
/// the same host). The required tags are added there on every render.
struct HerLook: Codable {
    var positive: String
    var negative: String
    var savedAt: String?
    var required: Required?
    struct Required: Codable { let positive: [String]; let negative: [String] }
}

private struct Rendered: Decodable { let seed: Int; let images: [String] }

struct LookView: View {
    @Environment(Session.self) private var session
    @State private var saved: HerLook?
    @State private var positive = ""
    @State private var negative = ""
    @State private var preview: UIImage?
    @State private var seed: Int?
    @State private var keepFace = false
    @State private var drawing = false
    @State private var saving = false
    @State private var problem: String?

    /// The image server is on her host, one port over.
    private var artist: HaruClient {
        var parts = URLComponents(url: session.client.base, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.port = 8188
        parts.path = ""
        return HaruClient(base: parts.url ?? session.client.base)
    }

    private var changed: Bool { saved.map { $0.positive != positive || $0.negative != negative } ?? false }

    var body: some View {
        Form {
            Section {
                ZStack {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Preview of her look")
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground))
                            .aspectRatio(832.0 / 1216.0, contentMode: .fit)
                            .overlay { Text("Draw her to see these tags").foregroundStyle(.secondary) }
                    }
                    if drawing { ProgressView("Drawing… about 20 seconds").padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                }
                Button(drawing ? "Drawing…" : "Draw her") { Task { await draw() } }
                    .disabled(drawing || saved == nil)
                Toggle("Keep this face", isOn: $keepFace)
                    .disabled(seed == nil)
                if let seed { LabeledContent("Seed", value: String(seed)).textSelection(.enabled) }
            } footer: {
                Text("Keep this face reuses the last seed, so only your tag changes show.")
            }
            Section {
                TextEditor(text: $positive).frame(minHeight: 160).font(.callout.monospaced())
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                Text("Her tags")
            } footer: {
                Text("Comma-separated. (tag:1.3) makes one stronger. Always added: \(saved?.required?.positive.joined(separator: ", ") ?? "adult").")
            }
            Section {
                TextEditor(text: $negative).frame(minHeight: 120).font(.callout.monospaced())
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                Text("Never show")
            } footer: {
                Text("Always added: \(saved?.required?.negative.joined(separator: ", ") ?? "child, loli, shota").")
            }
            Section {
                Button(saving ? "Saving…" : "Save as her look") { Task { await save() } }
                    .disabled(saving || !changed)
                Button("Back to her saved look") { positive = saved?.positive ?? ""; negative = saved?.negative ?? "" }
                    .disabled(!changed)
                if let at = saved?.savedAt { LabeledContent("Last saved", value: at) }
            } footer: {
                Text("Her selfies use the saved look. Drawing here never changes it.")
            }
            if let problem { Section("Needs attention") { Text(problem) } }
        }
        .navigationTitle("Her look")
        .task(id: session.baseURLString) { await load() }
    }

    private func load() async {
        do {
            let look: HerLook = try await artist.get("/haru/look")
            saved = look
            positive = look.positive
            negative = look.negative
            problem = nil
        } catch {
            problem = "Her image server did not answer: \(error.localizedDescription)"
        }
    }

    private func draw() async {
        drawing = true
        defer { drawing = false }
        var request: [String: JSONValue] = ["positive": .string(positive), "negative": .string(negative)]
        if keepFace, let seed { request["seed"] = .number(Double(seed)) }
        do {
            let out: Rendered = try await artist.post("/haru/render", request)
            guard let first = out.images.first, let data = Data(base64Encoded: first), let image = UIImage(data: data) else {
                problem = "The picture came back empty."
                return
            }
            preview = image
            seed = out.seed
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let look: HerLook = try await artist.post("/haru/look", ["positive": .string(positive), "negative": .string(negative)])
            saved = look
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
