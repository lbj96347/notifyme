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
    static let kind = NotifyMeWidgetKeys.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NotifyMeWidgetProvider()) { entry in
            NotifyMeWidgetView(entry: entry)
        }
        .configurationDisplayName("NotifyMe")
        .description("Your latest notifications at a glance.")
        .supportedFamilies(Self.supportedFamilies)
    }

    /// Home Screen families on every supported OS, plus the lock-screen /
    /// StandBy accessory families when running on iOS 16+ (where WidgetKit first
    /// shipped `.accessory*`). The accessory families are appended behind an
    /// availability check so the same binary still installs on iOS 14–15, which
    /// don't know those `WidgetFamily` cases.
    private static var supportedFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        if #available(iOSApplicationExtension 16.0, iOS 16.0, *) {
            families.append(contentsOf: [
                .accessoryInline,
                .accessoryCircular,
                .accessoryRectangular,
            ])
        }
        return families
    }
}
