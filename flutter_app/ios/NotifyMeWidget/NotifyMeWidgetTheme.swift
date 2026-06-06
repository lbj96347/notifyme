import SwiftUI

// Retro palette + small formatting helpers for the widget surface.
//
// The widget can't reach the Flutter `RetroPalette` (Dart), so the handful of
// colors the widget draws are mirrored here from
// `lib/shared/retro_palette.dart`. Keep the two in lockstep: these are sampled
// from the app icon (a retro pager/beeper) and the closed webhook `status` set
// (green=success / red=error / yellow=warning / blue=info).

enum RetroWidgetPalette {
    // Structure — the molded charcoal pager body.
    static let background = Color(hex: 0x1A1820)
    static let surface = Color(hex: 0x2C2A30)
    static let surfaceRaised = Color(hex: 0x3A383F)
    static let outline = Color(hex: 0x4A4750)

    // Brand — the olive/sage LCD glow and its lit panel.
    static let primary = Color(hex: 0xA7B27C)
    static let lcdScreen = Color(hex: 0xB6C08A)
    static let lcdInk = Color(hex: 0x20221A)

    // Accents.
    static let accent = Color(hex: 0xE5732C) // warm lamp bloom
    static let led = Color(hex: 0xE23B2B)    // red LED dot / unread

    // Foreground.
    static let onSurface = Color(hex: 0xECEAE0)
    static let onSurfaceMuted = Color(hex: 0x9C988E)

    // Status (mirrors the webhook `status` contract).
    static let statusSuccess = Color(hex: 0x8FA651)
    static let statusError = led
    static let statusWarning = Color(hex: 0xE09A3C)
    static let statusInfo = Color(hex: 0x6E8FA2)

    /// Maps an item's normalized status keyword to its retro status color.
    static func statusColor(_ keyword: String) -> Color {
        switch keyword {
        case "success":
            return statusSuccess
        case "error":
            return statusError
        case "warning":
            return statusWarning
        default:
            return statusInfo
        }
    }
}

extension Color {
    /// Builds a `Color` from a `0xRRGGBB` literal so the palette can read like
    /// the Dart `Color(0xFF…)` constants it mirrors.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// Compact, pager-readout relative timestamps: `now`, `5m`, `2h`, `3d`, then an
/// absolute `MMM d` once a week old. Computed against a reference `now` (the
/// timeline entry's date) so the widget renders deterministically between
/// reloads rather than drifting per-frame.
enum RetroRelativeTime {
    static func short(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            return "now"
        }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        let days = hours / 24
        if days < 7 {
            return "\(days)d"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
