import 'package:flutter/material.dart';

/// The NotifyMe retro palette — the single source of truth for app color.
///
/// Every value here is sampled from the app icon (`assets/icon/icon.png`): a
/// retro pager/beeper with a warm charcoal body, an olive/sage LCD screen, a
/// black bell glyph, a vivid red LED dot, and a warm orange light bloom in the
/// corner. The app leans into that "device sitting on a desk in lamplight"
/// mood, so the palette is dark-forward and warm rather than clinical.
///
/// Use these constants instead of `Colors.*` or ad-hoc hex values so the retro
/// look stays consistent across features. Status colors live here too and are
/// consumed by [NotificationStatus]; keep the two in sync.
abstract final class RetroPalette {
  // --- Typography ----------------------------------------------------------

  /// The app's retro typeface — Share Tech Mono, a terminal/LCD-style monospace
  /// that mirrors the pager's readout while staying legible at body sizes.
  /// Bundled as a font asset (see `pubspec.yaml`) and applied globally via
  /// `ThemeData.fontFamily`, so it flows into every M3 text style without
  /// overriding their sizes/weights — text metrics shift to mono but the layout
  /// scale is untouched. Ships a single Regular weight; Flutter synthesizes the
  /// heavier weights the theme requests.
  static const String fontFamily = 'ShareTechMono';

  // --- Structure -----------------------------------------------------------

  /// App backdrop — the deep, slightly warm charcoal behind the pager body.
  static const Color background = Color(0xFF1A1820);

  /// Card / sheet surface — the pager's molded charcoal body.
  static const Color surface = Color(0xFF2C2A30);

  /// Raised surface — buttons and pressed plastic, one step lighter.
  static const Color surfaceRaised = Color(0xFF3A383F);

  /// Hairline borders and dividers between molded panels.
  static const Color outline = Color(0xFF4A4750);

  // --- Surface container ramp ----------------------------------------------
  // Material 3 tints many components (NavigationBar, Dialog, Card) off the
  // `surfaceContainer*` roles rather than `surface`. The raw `ColorScheme(...)`
  // constructor leaves these unset, and their getters then fall back to plain
  // `surface` — flattening the molded-panel depth. Define an explicit dark ramp
  // so raised plastic reads as raised. Stepped between [background] and
  // [surfaceRaised].
  static const Color surfaceContainerLowest = Color(0xFF16141B);
  static const Color surfaceContainerLow = Color(0xFF211F26);
  static const Color surfaceContainer = Color(0xFF26242B);
  static const Color surfaceContainerHigh = Color(0xFF322F37);
  static const Color surfaceContainerHighest = surfaceRaised;

  // --- Brand ---------------------------------------------------------------

  /// Primary — the olive/sage glow of the LCD screen. This is the app's
  /// signature color (FilledButtons, active states, the brand mark).
  static const Color primary = Color(0xFFA7B27C);

  /// A dimmer primary for secondary fills and disabled-but-present states.
  static const Color primaryDim = Color(0xFF8C9A5E);

  /// The lit LCD panel itself — a pale yellow-green wash used as a backdrop
  /// for "screen"-styled surfaces (e.g. the empty-inbox readout).
  static const Color lcdScreen = Color(0xFFB6C08A);

  /// The black bell glyph / ink printed on the LCD — text on [lcdScreen].
  static const Color lcdInk = Color(0xFF20221A);

  /// Accent — the warm orange light bloom. Used sparingly for highlights,
  /// links, and focus rings to echo the lamplight in the icon.
  static const Color accent = Color(0xFFE5732C);

  /// The red LED status dot — high-energy alerts and the unread indicator.
  static const Color led = Color(0xFFE23B2B);

  // --- Foreground ----------------------------------------------------------

  /// Primary text/icons on dark surfaces — a warm off-white, not pure white.
  static const Color onSurface = Color(0xFFECEAE0);

  /// Muted secondary text — captions, timestamps, hints.
  static const Color onSurfaceMuted = Color(0xFF9C988E);

  /// Foreground on top of [primary] (e.g. button labels) — the dark ink that
  /// reads as "printed on the LCD."
  static const Color onPrimary = Color(0xFF20221A);

  /// A subtle divider/border tone, dimmer than [outline]. Without this the
  /// `outlineVariant` getter falls back to `onSurface` (the near-white body
  /// text color), so Dividers render as a heavy bright rule on dark surfaces.
  static const Color outlineVariant = Color(0xFF3A383F);

  // --- Error container -----------------------------------------------------
  // Backdrop + foreground for error banners (e.g. the sign-in error). Left
  // unset, `errorContainer` falls back to the full-saturation LED red [led]
  // with off-white text — a loud fill that's both off-palette and low-contrast
  // (~3.6:1). These give a deep, warm muted red panel with legible light text.

  /// Error banner background — a deep, warm muted red that sits in the dark
  /// world rather than shouting like the LED dot.
  static const Color errorContainer = Color(0xFF5C2A24);

  /// Text/icons on [errorContainer] — a light warm red-tinted off-white
  /// (~8:1 against the container).
  static const Color onErrorContainer = Color(0xFFF4D0C9);

  // --- Status (closed set; mirrors the webhook `status` contract) ----------
  // Retro-toned so the inbox stays in the icon's world, with meanings kept:
  // green=success, red=error, yellow=warning, blue=info. Three of the four are
  // sampled straight from the icon (the LCD glow, the LED dot, the lamp bloom);
  // info is the one principled extension since the icon carries no blue.

  /// `status: success` — the LCD's olive/sage glow ([primary] sampled at
  /// ~#A1B179), deepened so it reads as a distinct "go" green against the warm
  /// off-white text rather than blending into the brand color.
  static const Color statusSuccess = Color(0xFF8FA651);

  /// `status: error` — the icon's red LED dot, reusing [led] so "error" and the
  /// unread indicator speak with the same alarm voice.
  static const Color statusError = led;

  /// `status: warning` — warm lamp amber pulled from the orange corner bloom
  /// ([accent] ~#E5732C) and lifted toward yellow so it stays clear of the LED
  /// red while keeping the lamplight warmth.
  static const Color statusWarning = Color(0xFFE09A3C);

  /// `status: info` — a muted, dusty retro blue. The icon has no blue, so this
  /// is desaturated and slightly warm to sit in the dark-forward world instead
  /// of reading as a clinical Material blue.
  static const Color statusInfo = Color(0xFF6E8FA2);

  /// The dark [ColorScheme] that wires this palette into Material 3. The app is
  /// dark-forward to match the icon, so this is the canonical scheme.
  static const ColorScheme colorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: primaryDim,
    onPrimaryContainer: onPrimary,
    secondary: accent,
    onSecondary: onPrimary,
    secondaryContainer: surfaceRaised,
    onSecondaryContainer: onSurface,
    tertiary: led,
    onTertiary: onSurface,
    error: statusError,
    onError: onSurface,
    errorContainer: errorContainer,
    onErrorContainer: onErrorContainer,
    surface: surface,
    onSurface: onSurface,
    onSurfaceVariant: onSurfaceMuted,
    surfaceContainerLowest: surfaceContainerLowest,
    surfaceContainerLow: surfaceContainerLow,
    surfaceContainer: surfaceContainer,
    surfaceContainerHigh: surfaceContainerHigh,
    surfaceContainerHighest: surfaceContainerHighest,
    outline: outline,
    outlineVariant: outlineVariant,
  );
}
