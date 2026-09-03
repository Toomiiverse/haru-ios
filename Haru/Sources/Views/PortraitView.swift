import SwiftUI

/// Her portrait, the app's own icon, as a circle. Served before the login.
struct PortraitView: View {
    @Environment(Session.self) private var session
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(.quaternary)
            }
        }
        .clipShape(Circle())
        .task {
            if let data = try? await session.client.bytes("/portrait") { image = UIImage(data: data) }
        }
    }
}
