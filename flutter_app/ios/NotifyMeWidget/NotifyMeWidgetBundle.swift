import SwiftUI
import WidgetKit

// Entry point for the WidgetKit extension. `kind` ("NotifyMeWidget") must match
// the `iOSName` the Flutter app passes to `HomeWidget.updateWidget(...)` (see
// `HomeWidgetService.defaultIosWidgetName`) so app-triggered refreshes target
// this widget.

@main
struct NotifyMeWidgetBundle: WidgetBundle {
    var body: some Widget {
        NotifyMeWidget()
    }
}

struct NotifyMeWidget: Widget {
    static let kind = "NotifyMeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NotifyMeWidgetProvider()) { entry in
            NotifyMeWidgetView(entry: entry)
        }
        .configurationDisplayName("NotifyMe")
        .description("Your latest notifications at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
