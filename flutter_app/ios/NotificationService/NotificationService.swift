import OSLog
import UserNotifications
import WidgetKit

/// Lightweight logger so extension execution can be confirmed on device via
/// Console.app / `log stream` (filter on subsystem `com.asktobuild.notifyme`,
/// category `NotificationService`). The extension runs in its own short-lived
/// process, so a plain log line is the simplest proof it was invoked.
private let serviceLog = Logger(
    subsystem: "com.asktobuild.notifyme",
    category: "NotificationService"
)

// Notification Service Extension.
//
// iOS hands every push that carries `mutable-content: 1` to this extension
// *before* it is shown, on its own background process — even when the app is
// backgrounded or terminated. The backend sets that flag (see
// `firebase_functions/src/messaging.ts`), so this runs for each delivered
// notification and gets a brief window to mutate the banner and/or do side work.
//
// We don't change the banner; we use the window to keep the home-screen widget
// fresh without waiting for the user to open the app. The widget can only render
// the App Group snapshot the app mirrors into shared storage (see
// `lib/features/widget/home_widget_service.dart`); between app launches that
// snapshot goes stale. Here we parse the incoming push, optimistically prepend it
// to that shared snapshot using the *same* schema the widget consumes
// (`NotifyMeWidgetItem` / `NotifyMeWidgetKeys`, shared via
// `NotifyMeWidgetSnapshot.swift`), and ask WidgetKit to reload the timeline.
//
// This is purely additive to the existing app-open sync: when the app next runs,
// `HomeWidgetService.sync` overwrites the whole snapshot from Firestore (the
// authoritative source), so any optimistic item written here is reconciled — and
// de-duped by id in the meantime so a row never appears twice.
class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        // Confirm the extension actually ran for this push. `notificationId` is the
        // backend's correlation id; it may be absent on alert-only pushes.
        let notificationId = request.content.userInfo["notificationId"] as? String ?? "<none>"
        serviceLog.log("didReceive invoked (notificationId: \(notificationId, privacy: .public))")

        // Best-effort widget mirror; never let it block or alter the banner.
        WidgetSnapshotWriter.record(from: request.content.userInfo)

        deliver()
    }

    override func serviceExtensionTimeWillExpire() {
        // The system is about to kill the extension — deliver whatever we have so
        // the banner still shows.
        serviceLog.log("serviceExtensionTimeWillExpire — delivering best-attempt content")
        deliver()
    }

    /// Hand the (unchanged) content back to the system exactly once.
    private func deliver() {
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(bestAttemptContent ?? UNNotificationContent())
    }
}

/// Mirrors a single incoming push into the shared App Group widget snapshot.
///
/// Reuses the widget's own `NotifyMeWidgetKeys` / `NotifyMeWidgetItem` (the file
/// is a member of both the widget and this extension's targets) so the snapshot
/// it writes is byte-compatible with what `NotifyMeWidgetSnapshot.load()` reads.
enum WidgetSnapshotWriter {
    /// Keep the shared snapshot bounded; mirrors `HomeWidgetService.defaultMaxItems`.
    static let maxItems = 10

    /// Parse `userInfo`, prepend it to the snapshot, recompute the unread count
    /// and write timestamp, and reload the widget timeline. All best-effort: any
    /// missing piece simply skips the mirror rather than throwing.
    static func record(from userInfo: [AnyHashable: Any], now: Date = Date()) {
        guard let defaults = UserDefaults(suiteName: NotifyMeWidgetKeys.appGroupId) else {
            serviceLog.error(
                "widget mirror skipped: App Group unavailable (\(NotifyMeWidgetKeys.appGroupId, privacy: .public))"
            )
            return
        }

        guard let item = makeItem(from: userInfo, now: now) else {
            serviceLog.error(
                "widget mirror skipped: payload did not contain notificationId/title/body"
            )
            return
        }

        var items = loadItems(defaults)
        // Drop any existing copy of this notification (a re-delivered push, or one
        // the app already synced) so it can't render twice; blank ids never match.
        items.removeAll { !$0.id.isEmpty && $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        let unread = items.filter { !$0.read }.count
        let stamp = Int64((now.timeIntervalSince1970 * 1000).rounded())

        if let data = try? JSONEncoder().encode(items),
           let json = String(data: data, encoding: .utf8) {
            // Values are stored as strings to match the `home_widget` writer and
            // the widget's `defaults.string(forKey:)` reads.
            defaults.set(json, forKey: NotifyMeWidgetKeys.items)
        }
        defaults.set(String(unread), forKey: NotifyMeWidgetKeys.unread)
        defaults.set(String(stamp), forKey: NotifyMeWidgetKeys.updated)

        WidgetCenter.shared.reloadTimelines(ofKind: NotifyMeWidgetKeys.widgetKind)
        serviceLog.log(
            "widget mirror wrote \(items.count, privacy: .public) item(s), unread=\(unread, privacy: .public), reloaded kind=\(NotifyMeWidgetKeys.widgetKind, privacy: .public)"
        )
    }

    /// Decode the currently-stored items, tolerating a missing/corrupt blob.
    private static func loadItems(_ defaults: UserDefaults) -> [NotifyMeWidgetItem] {
        guard let raw = defaults.string(forKey: NotifyMeWidgetKeys.items),
              let data = raw.data(using: .utf8)
        else { return [] }
        return (try? JSONDecoder().decode([NotifyMeWidgetItem].self, from: data)) ?? []
    }

    /// Build a widget item from the FCM/APNs payload.
    ///
    /// The backend's `data` block carries flat string fields (`notificationId`,
    /// `title`, `body`, `status`, `category`, optional `url`); we fall back to the
    /// `aps.alert` block for title/body so a notification with only an alert still
    /// mirrors. Returns `nil` when there's nothing worth showing.
    private static func makeItem(
        from userInfo: [AnyHashable: Any],
        now: Date
    ) -> NotifyMeWidgetItem? {
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let alert = aps?["alert"] as? [AnyHashable: Any]

        let id = string(userInfo["notificationId"]) ?? ""
        let title = string(userInfo["title"]) ?? string(alert?["title"]) ?? ""
        let body = string(userInfo["body"]) ?? string(alert?["body"]) ?? ""
        let status = string(userInfo["status"]) ?? "info"
        let category = string(userInfo["category"]) ?? ""
        let url = nonEmpty(string(userInfo["url"]))

        // A push with no id, title and body is not worth mirroring.
        if id.isEmpty, title.isEmpty, body.isEmpty {
            return nil
        }

        return NotifyMeWidgetItem(
            id: id,
            title: title,
            body: body,
            status: status,
            category: category,
            receivedAt: Int64((now.timeIntervalSince1970 * 1000).rounded()),
            read: false,
            url: url
        )
    }

    /// Coerce a JSON/userInfo value to a `String` (handles `NSString` and the
    /// numeric/`NSNumber` cases APNs occasionally produces for a plain string).
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }

    /// Nil out empty/whitespace-only strings so an absent `url` stays absent.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
