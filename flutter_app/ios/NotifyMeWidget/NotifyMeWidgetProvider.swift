import WidgetKit

// Feeds the widget its timeline. Each entry is just the current shared snapshot;
// the app drives freshness by calling `HomeWidget.updateWidget(...)` after every
// inbox sync, so the provider only needs to read once per refresh request. We
// still schedule a periodic reload as a safety net in case an update call is
// dropped (e.g. the app was killed before it could ask for a redraw).

struct NotifyMeWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: NotifyMeWidgetSnapshot

    static let placeholder = NotifyMeWidgetEntry(
        date: Date(timeIntervalSince1970: 0),
        snapshot: {
            #if DEBUG
            return .preview
            #else
            return .empty
            #endif
        }()
    )
}

struct NotifyMeWidgetProvider: TimelineProvider {
    /// Skeleton/redacted state shown while WidgetKit is still loading real data.
    func placeholder(in context: Context) -> NotifyMeWidgetEntry {
        .placeholder
    }

    /// Snapshot for the widget gallery and transient system requests.
    func getSnapshot(
        in context: Context,
        completion: @escaping (NotifyMeWidgetEntry) -> Void
    ) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        completion(currentEntry())
    }

    /// One entry now, plus a reload an hour out as a backstop.
    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<NotifyMeWidgetEntry>) -> Void
    ) {
        let entry = currentEntry()
        let nextReload = Calendar.current.date(
            byAdding: .hour, value: 1, to: entry.date
        ) ?? entry.date.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextReload)))
    }

    private func currentEntry() -> NotifyMeWidgetEntry {
        let snapshot = NotifyMeWidgetSnapshot.load()
        // The entry's `date` is the render clock for relative timestamps and the
        // staleness check, so it must be real "now" — not the snapshot's sync
        // time (which would make every "n ago" read as the moment of sync and
        // staleness never trigger). It's captured once per timeline build, so
        // renders between reloads stay stable rather than drifting per-frame.
        return NotifyMeWidgetEntry(date: Date(), snapshot: snapshot)
    }
}
