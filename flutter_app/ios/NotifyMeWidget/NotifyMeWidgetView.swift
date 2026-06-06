import SwiftUI
import WidgetKit

// The widget's SwiftUI surface. Three families, each tolerant of degenerate data:
//
//   - empty  : nothing synced yet / signed out — a prompt to open the app.
//   - small  : a single-card readout of the latest notification.
//   - medium : a compact 3-row list, each row a deep-link `Link`.
//   - large  : a "beeper readout" — the latest five notifications styled like
//              the app icon's pager LCD, plus a "More" target opening the inbox.
//
// Robustness baked into every family (see `NotifyMeWidgetSnapshot`):
//   - stale snapshot   : when the app hasn't synced past `staleThreshold`, the
//                        header flags the cached data as out of date.
//   - missing fields   : blank titles fall back to "(no title)", empty bodies are
//                        dropped, blank categories show "GENERAL" (tolerant decode).
//   - unknown status   : non-canonical `status` maps to the info color.
//   - long title/body  : single/few-line caps with tail truncation; the relative
//                        time always wins layout over a long category label.
//
// Colors come from `RetroWidgetPalette` (mirrors the app's `RetroPalette`); deep
// links match the routes wired in `notification_tap_router.dart`
// (`notifyme://notification/{id}` per row, `notifyme://inbox` for header/More).
// Small widgets ignore inner `Link`s — the whole tile is a single tap target —
// so the small layout deep-links the latest notification via `widgetURL` (and
// falls back to the inbox when that row carries no usable id).

struct NotifyMeWidgetView: View {
    let entry: NotifyMeWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetContainerBackground(RetroWidgetPalette.background)
            .widgetURL(widgetURL)
    }

    /// The widget shows only unread messages; once read they drop off (reflected
    /// on the next app sync) and it falls back to the idle empty state.
    private var snapshot: NotifyMeWidgetSnapshot { entry.snapshot.unreadOnly }

    /// Whole-widget tap target. The small family draws no inner `Link`s, so it
    /// resolves to the latest notification's detail (or the inbox when that row
    /// has no usable id); medium/large fall back to the inbox here and override
    /// per-row with their own `Link`s.
    private var widgetURL: URL? {
        if family == .systemSmall,
           let latest = snapshot.items.first,
           latest.canDeepLink {
            return URL(string: "notifyme://notification/\(latest.id)")
        }
        return URL(string: "notifyme://inbox")
    }

    /// Whether the cached snapshot is old enough to flag as out of date.
    private var isStale: Bool { snapshot.isStale(asOf: entry.date) }

    @ViewBuilder
    private var content: some View {
        if snapshot.isEmpty {
            EmptyStateView()
        } else if family == .systemSmall {
            SmallLatestView(snapshot: snapshot, now: entry.date, isStale: isStale)
        } else if family == .systemLarge {
            BeeperLargeView(snapshot: snapshot, now: entry.date, isStale: isStale)
        } else {
            MediumListView(snapshot: snapshot, now: entry.date, maxRows: 3, isStale: isStale)
        }
    }
}

// MARK: - Container background

private extension View {
    /// iOS 17 requires widgets to declare their background through
    /// `containerBackground(for: .widget)` (a plain `.background` triggers the
    /// "Please adopt containerBackground API" placeholder, and the system can't
    /// remove the background in contexts like StandBy). Falls back to `.background`
    /// on iOS 14–16 where the API doesn't exist.
    @ViewBuilder
    func widgetContainerBackground(_ color: Color) -> some View {
        if #available(iOSApplicationExtension 17.0, iOS 17.0, *) {
            containerBackground(color, for: .widget)
        } else {
            background(color)
        }
    }
}

// MARK: - Small "latest" layout

/// The single-card layout: the latest notification rendered like one cell of the
/// pager LCD. The whole tile deep-links to its detail (see `widgetURL` above).
private struct SmallLatestView: View {
    let snapshot: NotifyMeWidgetSnapshot
    let now: Date
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                    .foregroundColor(RetroWidgetPalette.primary)
                Text("NotifyMe")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(RetroWidgetPalette.primary)

                Spacer(minLength: 0)

                if isStale {
                    StaleBadge(compact: true)
                } else if snapshot.unreadCount > 0 {
                    Text("\(snapshot.unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(RetroWidgetPalette.lcdInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(RetroWidgetPalette.led))
                }
            }

            if let item = snapshot.items.first {
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(RetroWidgetPalette.statusColor(item.statusColorName))
                        .frame(width: 9, height: 9)
                        .padding(.top, 4)

                    Text(item.displayTitle)
                        .font(.subheadline.weight(item.read ? .regular : .semibold))
                        .foregroundColor(RetroWidgetPalette.onSurface)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                if item.hasBody {
                    Text(item.body)
                        .font(.caption)
                        .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    Text(item.displayCategory)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(RetroWidgetPalette.statusColor(item.statusColorName))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let received = item.receivedDate {
                        Text("·")
                            .font(.caption2)
                            .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
                            .layoutPriority(1)
                        Text(RetroRelativeTime.short(received, now: now))
                            .font(.caption2)
                            .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                }
            }

            PagerButtonBar(compact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }
}

// MARK: - Large "beeper" layout

/// The flagship layout: a pager-style readout of the latest five notifications.
private struct BeeperLargeView: View {
    let snapshot: NotifyMeWidgetSnapshot
    let now: Date
    let isStale: Bool

    /// The driving spec: latest five messages.
    private static let rowCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Link(destination: URL(string: "notifyme://inbox")!) {
                ReadoutHeader(
                    unreadCount: snapshot.unreadCount,
                    updatedAt: snapshot.updatedAt,
                    now: now,
                    isStale: isStale
                )
            }

            let items = Array(snapshot.items.prefix(Self.rowCount))
            VStack(spacing: 0) {
                // Keyed by position, not id: a malformed snapshot can carry rows
                // with blank/duplicate ids, which would collide as `ForEach` keys.
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Divider().overlay(RetroWidgetPalette.outline.opacity(0.4))
                    }
                    deepLinked(item) {
                        BeeperRow(item: item, now: now)
                    }
                }
            }

            Spacer(minLength: 0)

            MoreButton(hiddenCount: max(0, snapshot.items.count - items.count))

            PagerButtonBar()
                .padding(.top, 10)
        }
        .padding(14)
    }

    /// Each row deep-links to its detail screen by id; the app falls back to the
    /// inbox if the document can't be resolved. Rows with no usable id (malformed
    /// snapshot) link to the inbox rather than a dead `notification/` URL.
    @ViewBuilder
    private func deepLinked<Content: View>(
        _ item: NotifyMeWidgetItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let destination = item.canDeepLink
            ? URL(string: "notifyme://notification/\(item.id)")
            : URL(string: "notifyme://inbox")
        if let destination {
            Link(destination: destination) { content() }
        } else {
            content()
        }
    }
}

/// The pager's "screen" header: brand mark, last-sync time, and an unread pill.
private struct ReadoutHeader: View {
    let unreadCount: Int
    let updatedAt: Date?
    let now: Date
    let isStale: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.fill")
                .font(.caption2)
                .foregroundColor(RetroWidgetPalette.primary)
            Text("NotifyMe")
                .font(.caption.weight(.semibold))
                .foregroundColor(RetroWidgetPalette.primary)

            Spacer()

            if isStale {
                StaleBadge(compact: false)
            } else {
                if let updatedAt {
                    Text(RetroRelativeTime.short(updatedAt, now: now))
                        .font(.caption2)
                        .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
                }
                if unreadCount > 0 {
                    Text("\(unreadCount) new")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(RetroWidgetPalette.lcdInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(RetroWidgetPalette.led))
                }
            }
        }
        .padding(.bottom, 8)
    }
}

/// Out-of-date indicator shown in headers when the cached snapshot is older than
/// `NotifyMeWidgetSnapshot.staleThreshold`. Drawn in the warning tone so it reads
/// as "this may not be current" without alarming like an error. The compact form
/// (small family) drops the label and shows just the glyph.
private struct StaleBadge: View {
    let compact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2.weight(.bold))
            if !compact {
                Text("Stale")
                    .font(.caption2.weight(.bold))
            }
        }
        .foregroundColor(RetroWidgetPalette.lcdInk)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(RetroWidgetPalette.statusWarning))
    }
}

/// One notification, beeper-styled: a status LED, title + body preview, and a
/// footer line carrying the source category and a relative received time.
private struct BeeperRow: View {
    let item: NotifyMeWidgetItem
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(RetroWidgetPalette.statusColor(item.statusColorName))
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(item.read ? .regular : .semibold))
                    .foregroundColor(RetroWidgetPalette.onSurface)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if item.hasBody {
                    Text(item.body)
                        .font(.caption)
                        .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 5) {
                    Text(item.displayCategory)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(RetroWidgetPalette.statusColor(item.statusColorName))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let received = item.receivedDate {
                        Text("·")
                            .font(.caption2)
                            .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
                            .layoutPriority(1)
                        Text(RetroRelativeTime.short(received, now: now))
                            .font(.caption2)
                            .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}

/// The "More" target — opens the inbox to see notifications beyond the five
/// shown. Always present (the inbox holds the full, scrollable history); when
/// extra items were trimmed it surfaces the count.
private struct MoreButton: View {
    let hiddenCount: Int

    var body: some View {
        Link(destination: URL(string: "notifyme://inbox")!) {
            HStack(spacing: 6) {
                Text(hiddenCount > 0 ? "\(hiddenCount) more in inbox" : "Open inbox")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .foregroundColor(RetroWidgetPalette.accent)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Medium layout

private struct MediumListView: View {
    let snapshot: NotifyMeWidgetSnapshot
    let now: Date
    let maxRows: Int
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(destination: URL(string: "notifyme://inbox")!) {
                ReadoutHeader(
                    unreadCount: snapshot.unreadCount,
                    updatedAt: snapshot.updatedAt,
                    now: now,
                    isStale: isStale
                )
            }

            // Keyed by position, not id: a malformed snapshot can carry rows with
            // blank/duplicate ids, which would collide as `ForEach` keys.
            ForEach(Array(snapshot.items.prefix(maxRows).enumerated()), id: \.offset) { _, item in
                row(for: item)
            }

            Spacer(minLength: 0)

            PagerButtonBar()
        }
        .padding(12)
    }

    @ViewBuilder
    private func row(for item: NotifyMeWidgetItem) -> some View {
        // No usable id (malformed row) → fall back to the inbox rather than a
        // dead `notification/` URL.
        let destination = item.canDeepLink
            ? URL(string: "notifyme://notification/\(item.id)")
            : URL(string: "notifyme://inbox")
        if let destination {
            Link(destination: destination) { CompactRow(item: item, now: now) }
        } else {
            CompactRow(item: item, now: now)
        }
    }
}

private struct CompactRow: View {
    let item: NotifyMeWidgetItem
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(RetroWidgetPalette.statusColor(item.statusColorName))
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayTitle)
                        .font(.subheadline.weight(item.read ? .regular : .semibold))
                        .foregroundColor(RetroWidgetPalette.onSurface)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let received = item.receivedDate {
                        Text(RetroRelativeTime.short(received, now: now))
                            .font(.caption2)
                            .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                if item.hasBody {
                    Text(item.body)
                        .font(.caption)
                        .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

// MARK: - Empty state

/// Idle-pager empty state: even with nothing synced, the widget reads like a
/// powered-on beeper — a status header with faux device indicators, a lit LCD
/// panel showing a "no messages" readout and a block cursor, and (on the larger
/// families) idle readout lines and an "awaiting signal" footer.
private struct EmptyStateView: View {
    @Environment(\.widgetFamily) private var family

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 8 : 10) {
            HStack(spacing: 6) {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                    .foregroundColor(RetroWidgetPalette.primary)
                Text("NotifyMe")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(RetroWidgetPalette.primary)

                Spacer(minLength: 0)

                PagerIndicators()
            }

            LcdPanel(family: family)

            if family == .systemLarge {
                Text("Open NotifyMe to get started")
                    .font(.caption)
                    .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
            }

            if !isSmall {
                PagerButtonBar()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }
}

/// A row of decorative pager keys — molded charcoal buttons that read like a
/// real beeper's keypad. Non-interactive (WidgetKit can't host controls here);
/// they exist purely for the retro device vibe. The `compact` form (small family
/// / dense rows) drops the stamped READ key and tightens the caps.
private struct PagerButtonBar: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            PagerKey(systemName: "chevron.up", compact: compact)
            PagerKey(systemName: "chevron.down", compact: compact)
            PagerKey(systemName: "envelope.fill", compact: compact)
            Spacer(minLength: 0)
            if !compact {
                PagerKey(label: "READ")
            }
        }
    }
}

/// One molded keypad button: a raised charcoal cap with an outline and a faint
/// top highlight, holding either an SF Symbol glyph or a short stamped label.
private struct PagerKey: View {
    var systemName: String? = nil
    var label: String? = nil
    var compact: Bool = false

    private var height: CGFloat { compact ? 18 : 22 }
    private var minWidth: CGFloat { compact ? 24 : 30 }

    var body: some View {
        Group {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: compact ? 9 : 11, weight: .bold))
            } else if let label {
                Text(label)
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(0.5)
            }
        }
        .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
        .frame(minWidth: minWidth)
        .frame(height: height)
        .padding(.horizontal, label == nil ? 0 : 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(RetroWidgetPalette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(RetroWidgetPalette.outline, lineWidth: 1)
        )
        .overlay(
            // Hairline sheen along the top edge to read as a molded plastic cap.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(height: 6)
                .padding(.horizontal, 2)
                .padding(.top, 1),
            alignment: .top
        )
    }
}

/// Faux device status row — signal + battery glyphs that sell the "powered-on
/// pager" read without claiming any real device state.
private struct PagerIndicators: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "antenna.radiowaves.left.and.right")
            Image(systemName: "battery.75")
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundColor(RetroWidgetPalette.onSurfaceMuted)
    }
}

/// The lit LCD readout. Monospaced ink-on-screen text plus a steady block cursor
/// (WidgetKit timelines are static, so the cursor is drawn solid rather than
/// blinking). The larger families fill the screen with idle dot rows and an
/// "awaiting signal" footer.
private struct LcdPanel: View {
    let family: WidgetFamily

    private var isSmall: Bool { family == .systemSmall }
    private var idleRows: Int { family == .systemLarge ? 4 : (isSmall ? 0 : 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text(isSmall ? "NO MSGS" : "NO NEW MESSAGES")
                    .font(.system(isSmall ? .caption : .footnote,
                                  design: .monospaced).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                CursorBlock()
            }
            .foregroundColor(RetroWidgetPalette.lcdInk)

            ForEach(0..<idleRows, id: \.self) { _ in
                Text(String(repeating: "·", count: 18))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(RetroWidgetPalette.lcdInk.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if !isSmall {
                Spacer(minLength: 0)
                Text("AWAITING SIGNAL")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundColor(RetroWidgetPalette.lcdInk.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(isSmall ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(RetroWidgetPalette.lcdScreen)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(RetroWidgetPalette.outline, lineWidth: 1)
        )
    }
}

/// A solid LCD block cursor, sized to sit just after the readout text.
private struct CursorBlock: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(RetroWidgetPalette.lcdInk)
            .frame(width: 7, height: 12)
            .padding(.leading, 3)
    }
}

#if DEBUG
struct NotifyMeWidgetView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NotifyMeWidgetView(
                entry: NotifyMeWidgetEntry(date: Date(), snapshot: .preview)
            )
            .previewContext(WidgetPreviewContext(family: .systemSmall))

            NotifyMeWidgetView(
                entry: NotifyMeWidgetEntry(date: Date(), snapshot: .preview)
            )
            .previewContext(WidgetPreviewContext(family: .systemLarge))

            NotifyMeWidgetView(
                entry: NotifyMeWidgetEntry(date: Date(), snapshot: .preview)
            )
            .previewContext(WidgetPreviewContext(family: .systemMedium))

            NotifyMeWidgetView(
                entry: NotifyMeWidgetEntry(date: Date(), snapshot: .empty)
            )
            .previewContext(WidgetPreviewContext(family: .systemMedium))

            // Stale snapshot — header flags the cached data as out of date.
            NotifyMeWidgetView(
                entry: NotifyMeWidgetEntry(date: Date(), snapshot: .stale)
            )
            .previewContext(WidgetPreviewContext(family: .systemLarge))

            NotifyMeWidgetView(
                entry: NotifyMeWidgetEntry(date: Date(), snapshot: .stale)
            )
            .previewContext(WidgetPreviewContext(family: .systemSmall))

            // Degenerate rows — blank title, no body, unknown status/category,
            // overlong title/body, missing id.
            NotifyMeWidgetView(
                entry: NotifyMeWidgetEntry(date: Date(), snapshot: .edgeCases)
            )
            .previewContext(WidgetPreviewContext(family: .systemLarge))

            NotifyMeWidgetView(
                entry: NotifyMeWidgetEntry(date: Date(), snapshot: .edgeCases)
            )
            .previewContext(WidgetPreviewContext(family: .systemMedium))

            NotifyMeWidgetView(
                entry: NotifyMeWidgetEntry(date: Date(), snapshot: .edgeCases)
            )
            .previewContext(WidgetPreviewContext(family: .systemSmall))
        }
    }
}
#endif
