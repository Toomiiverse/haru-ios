import SwiftUI

/// Her selfies, newest first. They live on her server only: this screen asks
/// /api/album for the list and reads each picture into memory, with no disk
/// cache and nothing offered to save to the phone.
struct AlbumPicture: Decodable, Identifiable, Hashable {
    let id: String
    let saved: String
    let isPrivate: Bool
    let at: String
    enum CodingKeys: String, CodingKey { case id, saved, isPrivate = "private", at }
}

private struct AlbumList: Decodable { let pictures: [AlbumPicture] }

/// Reads her pictures without leaving a copy on the phone: memory only, the
/// sign-in cookie from the shared jar.
private actor AlbumLoader {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    private var images: [String: UIImage] = [:]

    func image(_ saved: String, base: URL) async -> UIImage? {
        if let image = images[saved] { return image }
        var parts = URLComponents(url: base.appendingPathComponent("/api/attach/file"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "saved", value: saved)]
        guard let url = parts?.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        images[saved] = image
        return image
    }
}

struct AlbumView: View {
    @Environment(Session.self) private var session
    @State private var pictures: [AlbumPicture] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var open: AlbumPicture?
    private let loader = AlbumLoader()
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    var body: some View {
        ScrollView {
            if loaded && pictures.isEmpty && problem == nil {
                ContentUnavailableView("No selfies yet", systemImage: "photo.on.rectangle",
                                       description: Text("Ask her for a picture of herself and it will be kept here."))
                    .padding(.top, 80)
            }
            if let problem {
                Text(problem).foregroundStyle(.secondary).padding()
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(pictures) { picture in
                    Button { open = picture } label: {
                        AlbumTile(picture: picture, loader: loader, base: session.client.base)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(picture.isPrivate ? "Private selfie from \(Self.day(picture.at))" : "Selfie from \(Self.day(picture.at))")
                }
            }
            .padding(4)
        }
        .navigationTitle("Her photos")
        .refreshable { await load() }
        .task(id: session.baseURLString) { await load() }
        .fullScreenCover(item: $open) { picture in
            AlbumViewer(picture: picture, loader: loader, base: session.client.base)
        }
    }

    private func load() async {
        do {
            let list: AlbumList = try await session.client.get("/api/album")
            pictures = list.pictures
            problem = nil
        } catch HaruError.signedOut {
            session.signedIn = false
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    static func day(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter.withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private struct AlbumTile: View {
    let picture: AlbumPicture
    let loader: AlbumLoader
    let base: URL
    @State private var image: UIImage?

    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .aspectRatio(832.0 / 1216.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .blur(radius: picture.isPrivate ? 18 : 0)
                } else {
                    ProgressView()
                }
            }
            .overlay {
                if picture.isPrivate { Image(systemName: "eye.slash").foregroundStyle(.white).font(.title3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: picture.id) { image = await loader.image(picture.saved, base: base) }
    }
}

private struct AlbumViewer: View {
    let picture: AlbumPicture
    let loader: AlbumLoader
    let base: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .accessibilityLabel("Selfie")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .principal) { Text(AlbumView.day(picture.at)).font(.footnote).foregroundStyle(.white) }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task { image = await loader.image(picture.saved, base: base) }
    }
}
