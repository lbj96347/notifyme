import Foundation

// Decodes the JSON snapshot the Flutter app mirrors into the shared App Group
// container (see `lib/features/widget/home_widget_service.dart`). The widget
// process can't reach Firestore or the user's auth session, so this snapshot is
// the only data it ever renders.
//
// Wire contract (must stay in lockstep with the Dart `HomeWidgetService`):
//
//   UserDefaults(suiteName: appGroupId)
//     "notifyme_widget_items"   -> JSON array string, newest-first, of items:
//         { id, title, body, status, category, receivedAt, read, url }
//           - receivedAt: epoch milliseconds, or null while a serverTimestamp resolves
//           - url:        omitted entirely when absent
//     "notifyme_widget_unread"  -> stringified Int (count of unread items)
//     "notifyme_widget_updated" -> stringified Int (epoch ms of last write)

enum NotifyMeWidgetKeys {
    /// Shared App Group id. Must match `ios/Runner/Runner.entitlements`, the
    /// widget's own entitlements, and the Dart `HomeWidgetService.defaultAppGroupId`.
    static let appGroupId = "group.com.asktobuild.notifyme"

    static let items = "notifyme_widget_items"
    static let unread = "notifyme_widget_unread"
    static let updated = "notifyme_widget_updated"

    /// WidgetKit `kind`. Single source of truth shared by the widget's
    /// `StaticConfiguration` (`NotifyMeWidget.kind`), the Notification Service
    /// Extension's `WidgetCenter.reloadTimelines(ofKind:)`, and the Dart
    /// `HomeWidgetService.defaultIosWidgetName` (`updateWidget(iOSName:)`).
    static let widgetKind = "NotifyMeWidget"
}

/// One notification row as stored in the shared snapshot.
struct NotifyMeWidgetItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let status: String
    let category: String
    /// Epoch milliseconds, or `nil` while a freshly written timestamp resolves.
    let receivedAt: Int64?
    let read: Bool
    /// Present only when the notification is tappable.
    let url: String?

    /// The status color keyword from the closed backend set
    /// (success/error/warning/info). Unknown values fall back to `info`.
    var statusColorName: String {
        switch status {
        case "success", "error", "warning", "info":
            return status
        default:
            return "info"
        }
    }

    var receivedDate: Date? {
        guard let receivedAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(receivedAt) / 1000)
    }

    /// Title to draw. A notification can arrive with a blank/whitespace title
    /// (or a missing `title` field that defaulted to ""); fall back to a neutral
    /// label so the row never renders an empty line.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no title)" : trimmed
    }

    /// Whether to draw the body line at all — suppresses the empty/whitespace case.
    var hasBody: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Footer category label. Blank/missing category degrades to "GENERAL"
    /// rather than an empty chip; unknown (non-canonical) categories pass through
    /// uppercased, mirroring the inbox.
    var displayCategory: String {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "GENERAL" : trimmed.uppercased()
    }

    /// A row can be per-item deep-linked only when it carries a usable id; a
    /// blank id (malformed snapshot) routes to the inbox instead.
    var canDeepLink: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension NotifyMeWidgetItem {
    /// Tolerant decoding: every field except the optionals falls back to a safe
    /// default when absent or the wrong type, so one malformed field never drops
    /// the whole item (and a partially-written snapshot still renders). Defined in
    /// an extension to keep the synthesized memberwise initializer available.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        status = (try? container.decode(String.self, forKey: .status)) ?? "info"
        category = (try? container.decode(String.self, forKey: .category)) ?? ""
        receivedAt = (try? container.decodeIfPresent(Int64.self, forKey: .receivedAt)) ?? nil
        read = (try? container.decode(Bool.self, forKey: .read)) ?? false
        url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? nil
    }
}

/// The full set of data the widget renders in one timeline entry.
struct NotifyMeWidgetSnapshot {
    let items: [NotifyMeWidgetItem]
    let unreadCount: Int
    let updatedAt: Date?

    /// An empty snapshot — rendered before the app has ever synced, after
    /// sign-out, or if the shared container can't be read.
    static let empty = NotifyMeWidgetSnapshot(items: [], unreadCount: 0, updatedAt: nil)

    var isEmpty: Bool { items.isEmpty }

    /// Beyond this age since the last successful app sync, the cached items are
    /// flagged as possibly out of date. The app pushes a fresh snapshot after
    /// every inbox sync, so a stale gap means it hasn't run (offline / killed /
    /// backgrounded long enough that iOS stopped refreshing the widget).
    static let staleThreshold: TimeInterval = 24 * 60 * 60

    /// Whether the snapshot is older than `staleThreshold` relative to `now`.
    /// An unknown `updatedAt` (never synced) is not treated as stale — that case
    /// is the empty state instead.
    func isStale(asOf now: Date) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) >= Self.staleThreshold
    }

    /// A view of this snapshot limited to unread items. The widget surfaces only
    /// messages still needing attention; once read (reflected on the next app
    /// sync), they drop off and the widget falls back to its idle empty state.
    /// `unreadCount` is recomputed from the filtered set so the header pill always
    /// matches the rows actually shown.
    var unreadOnly: NotifyMeWidgetSnapshot {
        let unread = items.filter { !$0.read }
        return NotifyMeWidgetSnapshot(
            items: unread,
            unreadCount: unread.count,
            updatedAt: updatedAt
        )
    }

    /// Reads and decodes the latest snapshot from the shared App Group container.
    /// Any missing/corrupt data degrades to `.empty` rather than throwing, so the
    /// widget always has something to draw.
    static func load(
        from defaults: UserDefaults? = UserDefaults(suiteName: NotifyMeWidgetKeys.appGroupId)
    ) -> NotifyMeWidgetSnapshot {
        guard let defaults else { return .empty }

        let items = decodeItems(defaults.string(forKey: NotifyMeWidgetKeys.items))
        let unread = intValue(defaults.string(forKey: NotifyMeWidgetKeys.unread)) ?? 0
        let updatedMillis = intValue(defaults.string(forKey: NotifyMeWidgetKeys.updated))
        let updatedAt = updatedMillis.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }

        return NotifyMeWidgetSnapshot(
            items: items,
            unreadCount: unread,
            updatedAt: updatedAt
        )
    }

    private static func decodeItems(_ raw: String?) -> [NotifyMeWidgetItem] {
        guard let data = raw?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([NotifyMeWidgetItem].self, from: data)) ?? []
    }

    /// The Dart side writes integers as strings (`unread.toString()`); tolerate a
    /// raw `Int` too in case a future writer stores it natively.
    private static func intValue(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        return Int(raw)
    }
}

#if DEBUG
extension NotifyMeWidgetSnapshot {
    /// Deterministic data for Xcode previews and the WidgetKit placeholder.
    /// Six items with mixed statuses/categories: the medium/large layouts show
    /// the latest (`preview-1`) while the unread count reflects the full snapshot.
    static let preview = NotifyMeWidgetSnapshot(
        items: [
            NotifyMeWidgetItem(
                id: "preview-1",
                title: "CI passed",
                body: "All checks green on main",
                status: "success",
                category: "ci",
                receivedAt: 1_700_000_000_000,
                read: false,
                url: "https://ci.example/run/1"
            ),
            NotifyMeWidgetItem(
                id: "preview-2",
                title: "Claude finished",
                body: "Refactor task complete — 14 files changed",
                status: "info",
                category: "claude",
                receivedAt: 1_699_999_400_000,
                read: false,
                url: nil
            ),
            NotifyMeWidgetItem(
                id: "preview-3",
                title: "Deploy failed",
                body: "Step \"migrate\" exited 1 — rolling back",
                status: "error",
                category: "github-actions",
                receivedAt: 1_699_996_400_000,
                read: false,
                url: "https://example/run/3"
            ),
            NotifyMeWidgetItem(
                id: "preview-4",
                title: "Disk 85% full",
                body: "Crawler box approaching capacity",
                status: "warning",
                category: "n8n",
                receivedAt: 1_699_989_200_000,
                read: true,
                url: nil
            ),
            NotifyMeWidgetItem(
                id: "preview-5",
                title: "Codex run done",
                body: "Generated 3 patches, 0 conflicts",
                status: "success",
                category: "codex",
                receivedAt: 1_699_913_600_000,
                read: true,
                url: nil
            ),
            NotifyMeWidgetItem(
                id: "preview-6",
                title: "Nightly backup",
                body: "Snapshot stored to cold storage",
                status: "info",
                category: "bash",
                receivedAt: 1_699_827_200_000,
                read: true,
                url: nil
            ),
        ],
        unreadCount: 3,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_400)
    )

    /// Same items as `.preview`, but last synced well beyond `staleThreshold`
    /// (≈10 days before "now") so previews exercise the stale badge.
    static let stale = NotifyMeWidgetSnapshot(
        items: preview.items,
        unreadCount: preview.unreadCount,
        updatedAt: Date().addingTimeInterval(-10 * 24 * 60 * 60)
    )

    /// A large unread backlog: 128 unread rows so the count survives the view's
    /// `unreadOnly` recompute and trips the accessory cap (`AccessoryUnread.label`
    /// → "99+"). Exercises the circular dial's overflow guard and the rectangular
    /// header's "99+ NEW" tag so neither can outgrow the cramped Lock Screen
    /// surfaces. The newest row matches `.preview`'s latest so the headline reads
    /// naturally.
    static let highVolume: NotifyMeWidgetSnapshot = {
        let items = (0..<128).map { index in
            NotifyMeWidgetItem(
                id: "high-\(index)",
                title: index == 0 ? "CI passed" : "Backlog item \(index)",
                body: "Queued notification awaiting review",
                status: "info",
                category: "ci",
                receivedAt: 1_700_000_000_000 - Int64(index) * 60_000,
                read: false,
                url: nil
            )
        }
        return NotifyMeWidgetSnapshot(
            items: items,
            unreadCount: items.count,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
    }()

    /// Hostile/degenerate rows: an extreme title/body, a blank title with a
    /// missing body and an unknown status/category, and a row with no id (not
    /// deep-linkable). The overlong row is newest so the latest-message panel
    /// itself exercises title/body clamping. Confirms each layout stays intact
    /// and readable.
    static let edgeCases = NotifyMeWidgetSnapshot(
        items: [
            NotifyMeWidgetItem(
                id: "edge-1",
                title: String(repeating: "Very long title that should truncate ", count: 6),
                body: String(repeating: "A long body preview that keeps going and going. ", count: 8),
                status: "warning",
                category: "a-very-long-unknown-category-name",
                receivedAt: 1_700_000_000_000,
                read: false,
                url: nil
            ),
            NotifyMeWidgetItem(
                id: "edge-2",
                title: "   ",
                body: "",
                status: "exploded",
                category: "",
                receivedAt: 1_699_999_400_000,
                read: false,
                url: nil
            ),
            NotifyMeWidgetItem(
                id: "",
                title: "No id — falls back to inbox",
                body: "This row can't be per-item deep-linked",
                status: "success",
                category: "claude",
                receivedAt: 1_699_996_400_000,
                read: true,
                url: nil
            ),
        ],
        unreadCount: 2,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_400)
    )
}
#endif
