/// Whether [url] is acceptable as a bookmark's link.
///
/// A bookmark link must parse and carry both a scheme and an authority (host) —
/// e.g. `https://example.com` — which is exactly what `BrowserScreen` needs to
/// load it with `Uri.parse`. Surrounding whitespace is ignored; `null`, empty,
/// scheme-less (`example.com`) and authority-less (`mailto:a@b.com`) strings are
/// all rejected.
///
/// This is the single source of truth shared by the add/edit form's validator
/// and the row's open handler, so both agree on what "valid" means.
bool isValidBookmarkUrl(String? url) {
  final trimmed = url?.trim() ?? '';
  if (trimmed.isEmpty) return false;
  final uri = Uri.tryParse(trimmed);
  return uri != null && uri.hasScheme && uri.hasAuthority;
}
