import UserNotifications

/// Notification Service Extension.
///
/// On a `mutable-content: 1` push — the DM push the backend sends from
/// `functions/bootstrap/notifications_dispatch._deliver_data` — this downloads
/// the sender's public avatar from the `sender_photo_url` field in the payload
/// and attaches it (`UNNotificationAttachment`), so the banner / lock-screen
/// shows the sender's photo instead of only the Ayma app icon.
///
/// Every failure path (no URL, non-HTTPS, bad status, timeout, unsupported
/// image) falls back to the unmodified alert — the message is never dropped.
/// Only the sender's own public avatar URL is read; no other payload data is
/// used or exfiltrated.
class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var downloadTask: URLSessionTask?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        self.bestAttempt = mutable

        guard let content = mutable else {
            contentHandler(request.content)
            return
        }

        let info = content.userInfo
        guard
            let urlString = info["sender_photo_url"] as? String,
            urlString.hasPrefix("https://"),
            let url = URL(string: urlString)
        else {
            contentHandler(content)
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        downloadTask = session.downloadTask(with: url) { [weak self] location, response, error in
            guard let self = self else { return }
            defer {
                // Always deliver, with or without the image.
                self.contentHandler?(self.bestAttempt ?? content)
            }
            guard
                error == nil,
                let location = location,
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else { return }

            let ext = self.fileExtension(for: http.mimeType)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: location, to: tmp)
                let attachment = try UNNotificationAttachment(
                    identifier: "sender_avatar",
                    url: tmp,
                    options: nil
                )
                self.bestAttempt?.attachments = [attachment]
            } catch {
                // Keep the plain alert — a broken image must never drop the push.
            }
        }
        downloadTask?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        // The system is about to kill us — deliver whatever we have so far.
        downloadTask?.cancel()
        if let handler = contentHandler {
            handler(bestAttempt ?? UNMutableNotificationContent())
        }
    }

    /// Maps a response MIME type to a file extension iOS can render as a
    /// notification attachment; defaults to `jpg` (our avatars are JPEG/PNG).
    private func fileExtension(for mimeType: String?) -> String {
        switch mimeType {
        case "image/png": return "png"
        case "image/gif": return "gif"
        default: return "jpg"
        }
    }
}
