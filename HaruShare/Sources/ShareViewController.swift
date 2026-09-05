import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share to Haru" from any app: a link, some text, a picture — with a line
/// of your own if you want — straight into the chat, and her answer back in
/// the sheet. No jar of its own: the address and cookie the app leaves in
/// the App Group go on by hand. A picture is staged through /api/attach the
/// way the app's composer does it, then rides the message.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        self.model = model
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.collect() }
    }
}

@MainActor @Observable
final class ShareModel {
    enum Phase: Equatable { case collecting, ready, sending, sent(String), failed(String) }

    var phase: Phase = .collecting
    var note = ""
    private(set) var url: URL?
    private(set) var text: String?
    private(set) var image: UIImage?
    private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) { self.context = context }

    var hasSomething: Bool { image != nil || url != nil || !(text ?? "").isEmpty }

    /// What was shared, from the extension items: the first picture, the
    /// first link, the first run of text.
    func collect() async {
        let providers = (context?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        for provider in providers {
            if image == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = try? await provider.loadDataRepresentation(for: .image), let picture = UIImage(data: data) {
                    image = picture
                    continue
                }
            }
            if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                    if let link = item as? URL { url = link; continue }
                    if let data = item as? Data, let link = URL(dataRepresentation: data, relativeTo: nil) { url = link; continue }
                }
            }
            if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                    if let string = item as? String { text = string }
                    else if let data = item as? Data, let string = String(data: data, encoding: .utf8) { text = string }
                }
            }
        }
        phase = .ready
    }

    func send() async {
        guard let base = Shared.base, let cookie = Shared.cookie else {
            phase = .failed("Open Haru and sign in first.")
            return
        }
        var lines: [String] = []
        let own = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { lines.append(own) }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != url?.absoluteString { lines.append(text) }
        if let url { lines.append(url.absoluteString) }
        let message = lines.joined(separator: "\n")
        guard image != nil || !message.isEmpty else {
            phase = .failed("There is nothing to send.")
            return
        }
        phase = .sending
        let client = ShareClient(base: base, cookie: cookie)
        do {
            var attachments: [Any] = []
            if let image, let jpeg = Self.jpeg(image) {
                let staged = try await client.upload("api/attach", query: ["name": "shared.jpg"], data: jpeg, type: "image/jpeg")
                if let record = staged["attachment"] { attachments.append(record) }
            }
            var body: [String: Any] = ["text": message]
            if !attachments.isEmpty { body["attachments"] = attachments }
            let answer = try await client.post("api/chat", body)
            let reply = (answer["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .sent(reply.isEmpty ? "Sent. She read it and said nothing." : reply)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The sheet's one button, at the end: done if it went, cancel if not.
    func finish() {
        if case .sent = phase {
            context?.completeRequest(returningItems: nil)
        } else {
            context?.cancelRequest(withError: NSError(domain: "com.toomiiverse.haru.share", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not sent."]))
        }
    }

    /// Down to a size worth sending: the long side at most 1600 points.
    private static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 1600 ? 1600 / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat.default(); f.scale = 1; return f }())
        let drawn = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return drawn.jpegData(compressionQuality: 0.85)
    }
}

/// The two calls the sheet makes, with the cookie set by hand.
struct ShareClient {
    let base: URL
    let cookie: String

    enum Failure: LocalizedError {
        case status(Int, String)
        var errorDescription: String? {
            switch self {
            case .status(401, _): return "Haru signed this phone out. Open the app and sign in again."
            case .status(let code, let message): return message.isEmpty ? "Her server answered \(code)." : message
            }
        }
    }

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }

    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = request(path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        return try Self.answer(data, response)
    }

    func upload(_ path: String, query: [String: String], data: Data, type: String) async throws -> [String: Any] {
        var request = request(path, query: query, method: "POST")
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        let (out, response) = try await session.upload(for: request, from: data)
        return try Self.answer(out, response)
    }

    private func request(_ path: String, query: [String: String] = [:], method: String) -> URLRequest {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue("\(Shared.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func answer(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.status(code, object["error"] as? String ?? "") }
        return object
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                } header: {
                    Text("To Haru")
                }
                if !isSent {
                    Section {
                        TextField("Say something with it", text: $model.note, axis: .vertical)
                            .lineLimit(1...4)
                    }
                }
                switch model.phase {
                case .sent(let reply):
                    Section("She said") { Text(reply) }
                case .failed(let why):
                    Section { Text(why).foregroundStyle(.red) }
                default:
                    EmptyView()
                }
            }
            .navigationTitle("Share to Haru")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isSent ? "Done" : "Cancel") { model.finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .sending {
                        ProgressView()
                    } else if !isSent {
                        Button("Send") { Task { await model.send() } }
                            .disabled(model.phase == .collecting || !model.hasSomething && model.note.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var isSent: Bool {
        if case .sent = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var preview: some View {
        if let image = model.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let url = model.url {
            Label(url.absoluteString, systemImage: "link").lineLimit(3)
        } else if let text = model.text, !text.isEmpty {
            Text(text).lineLimit(6)
        } else if model.phase == .collecting {
            ProgressView()
        } else {
            Text("Nothing came through.").foregroundStyle(.secondary)
        }
    }
}
