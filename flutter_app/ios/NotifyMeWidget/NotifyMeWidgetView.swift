import SwiftUI
import WidgetKit

// The widget's SwiftUI surface. Three families, each tolerant of degenerate data:
//
//   - empty         : nothing synced yet / signed out — a prompt to open the app.
//   - small         : a single-card readout of the latest notification.
//   - medium / large: the latest notification rendered on the lit "beeper" LCD —
//                     the same retro screen styling as the empty state, but
//                     carrying a real message. The panel itself deep-links to
//                     the message detail. Large allows more body lines than
//                     medium.
//
// Robustness baked into every family (see `NotifyMeWidgetSnapshot`):
//   - stale snapshot   : when the app hasn't synced past `staleThreshold`, the
//                        header flags the cached data as out of date.
//   - missing fields   : blank titles fall back to "(no title)", empty bodies are
//                        dropped, blank categories show "GENERAL" (tolerant decode).
//   - unknown status   : non-canonical `status` maps to the info color.
//   - long title/body  : every line is clamped (the title scales down before it
//                        truncates; body and footer truncate at the tail) so the
//                        fixed widget canvas can never overflow.
//
// Colors come from `RetroWidgetPalette` (mirrors the app's `RetroPalette`); deep
// links match the routes wired in `notification_tap_router.dart`
// (`notifyme://notification/{id}` for the panel, `notifyme://inbox` for header).
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
        } else {
            BeeperLatestView(
                snapshot: snapshot,
                now: entry.date,
                family: family,
                isStale: isStale
            )
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

// MARK: - Medium / large "beeper" layout

/// The flagship layout for the medium and large families: the single latest
/// notification drawn on the lit beeper LCD. The LCD panel deep-links to the
/// message's detail; the header deep-links to the inbox.
private struct BeeperLatestView: View {
    let snapshot: NotifyMeWidgetSnapshot
    let now: Date
    let family: WidgetFamily
    let isStale: Bool

    private var isLarge: Bool { family == .systemLarge }

    /// Body lines the LCD affords. Mirrors the empty state's idle-row count per
    /// family (`LcdPanel.idleRows`): the large screen is tall enough for several,
    /// the medium screen for one, so neither family's panel can overflow.
    private var bodyLineLimit: Int { isLarge ? 4 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 10 : 6) {
            Link(destination: URL(string: "notifyme://inbox")!) {
                ReadoutHeader(
                    unreadCount: snapshot.unreadCount,
                    updatedAt: snapshot.updatedAt,
                    now: now,
                    isStale: isStale
                )
            }

            if let item = snapshot.items.first {
                latest(item)
            }

            PagerButtonBar()
                .padding(.top, isLarge ? 6 : 0)
        }
        .padding(isLarge ? 14 : 12)
    }

    /// The latest message panel, wrapped in a deep `Link` to its detail screen.
    /// A row with no usable id (malformed snapshot) falls back to the inbox
    /// rather than a dead `notification/` URL.
    @ViewBuilder
    private func latest(_ item: NotifyMeWidgetItem) -> some View {
        let panel = LcdMessagePanel(item: item, now: now, bodyLineLimit: bodyLineLimit)
        let destination = item.canDeepLink
            ? URL(string: "notifyme://notification/\(item.id)")
            : URL(string: "notifyme://inbox")
        if let destination {
            Link(destination: destination) { panel }
        } else {
            panel
        }
    }
}

/// The latest notification rendered as a lit beeper readout: it mirrors the idle
/// `LcdPanel` (monospaced ink on the olive screen, a block cursor trailing the
/// headline, the bordered panel that fills the screen area) but fills the screen
/// with a real message instead of the idle dots. Every line is clamped — the
/// title scales down before truncating, the body and footer truncate at the tail
/// — so the panel can never outgrow the fixed widget canvas.
private struct LcdMessagePanel: View {
    let item: NotifyMeWidgetItem
    let now: Date
    let bodyLineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Headline readout — the title, with the block cursor trailing it
            // exactly as the idle "NO NEW MESSAGES" line carries one.
            HStack(spacing: 0) {
                Text(item.displayTitle)
                    .font(.system(.footnote, design: .monospaced).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.tail)
                CursorBlock()
            }
            .foregroundColor(RetroWidgetPalette.lcdInk)

            // Body preview — dimmer ink, taking the place of the idle dot rows.
            if item.hasBody {
                Text(item.body)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(RetroWidgetPalette.lcdInk.opacity(0.7))
                    .lineLimit(bodyLineLimit)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            // Footer readout — status LED + source category + received time,
            // mirroring the idle "AWAITING SIGNAL" footer line.
            HStack(spacing: 5) {
                Circle()
                    .fill(RetroWidgetPalette.statusColor(item.statusColorName))
                    .frame(width: 7, height: 7)
                Text(item.displayCategory)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let received = item.receivedDate {
                    Text("·")
                        .layoutPriority(1)
                    Text(RetroRelativeTime.short(received, now: now))
                        .fixedSize()
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundColor(RetroWidgetPalette.lcdInk.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
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
