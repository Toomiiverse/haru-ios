import Intents
import UserNotifications

/// Her pushes, turned into messages from her before they show: a
/// communication notification carries her face where the app icon would be,
/// may break into a Focus that allows her as a contact, and is what AirPods
/// and CarPlay read out (with a spoken reply). The server marks every push
/// mutable-content (apnsPayload in haru-desktop/electron/apns.ts); the Reply
/// and Done buttons ride along untouched, since the category is kept.
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        deliver = contentHandler
        original = request.content
        Task {
            let image = await Portrait.image()
            let handle = INPersonHandle(value: "haru", type: .unknown)
            let her = INPerson(personHandle: handle, nameComponents: nil, displayName: "Haru", image: image, contactIdentifier: nil, customIdentifier: "haru")
            let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: request.content.body, speakableGroupName: nil, conversationIdentifier: "haru", serviceName: nil, sender: her, attachments: nil)
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            try? await interaction.donate()
            let content = (try? request.content.updating(from: intent)) ?? request.content
            finish(content)
        }
    }

    /// iOS is out of patience (about thirty seconds): the line as it came.
    override func serviceExtensionTimeWillExpire() {
        if let original { finish(original) }
    }

    private func finish(_ content: UNNotificationContent) {
        deliver?(content)
        deliver = nil
    }
}

/// Her picture is public on her server (/portrait). Kept in this extension's
/// own caches once fetched, so only the first line after an install waits for
/// it — and with the phone off the tailnet she simply shows without a face.
/// The address is the app's default (Session.defaultBase): the extension has
/// no App Group to read a changed one from, by choice — adding it to a new
/// App ID is a portal step the build cannot do.
enum Portrait {
    private static let address = URL(string: "https://haruserver.tail6da04d.ts.net/portrait")!
    private static var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("portrait.img")
    }

    static func image() async -> INImage? {
        if let file, let data = try? Data(contentsOf: file), !data.isEmpty { return INImage(imageData: data) }
        var request = URLRequest(url: address)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        if let file { try? data.write(to: file, options: .atomic) }
        return INImage(imageData: data)
    }
}
