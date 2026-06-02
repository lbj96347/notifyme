# features/bookmarks/

The Bookmarks tab: a live, newest-first list of the saved links the user has
kept, backed by a per-user Firestore subcollection at
`users/{uid}/bookmarks/{bookmarkId}` (scoped to the signed-in `uid` by the
document path itself).

A bookmark is its own document — not a starred notification. Each row shows the
title, the saved URL, when it was saved, and (once revisited) when it was last
checked, grouped under Today / Yesterday / older-date headers. Tapping a row
opens the link in an in-app browser (and stamps `lastCheckedAt`); the trailing overflow
menu edits the title/url or deletes the row (with a confirm step), letting the
live stream reflect either change. The floating **+** button opens the same form
in create mode (empty fields, URL required, title optional) to add a new one.

Laid out as a self-contained feature module:

- `models/` — `Bookmark` (an immutable saved link: `id`, `uid`, `title`, `url`,
  `createdAt`, `updatedAt`, `lastCheckedAt`, with Firestore serialization via
  `toMap` and parsing via `fromSnapshot`/`fromMap`) and `BookmarkDayGroup`
  (groups bookmarks under Today / Yesterday / older-date headers by `createdAt`).
- `repository/` — `BookmarkRepository` owns the Firestore access: the per-`uid`
  newest-first stream (`watchForUser`) and a single-document `fetchById`, plus
  the full CRUD write set — `add` (create), `update` (edit title/url),
  `touchLastChecked` (stamp a revisit), and `delete`. The subcollection path,
  field names, and ordering live here and stay in sync with the security rules.
- `widgets/` — the day-grouped list, the saved-link row tile, the row's
  edit/delete overflow menu, the shared create/edit dialog (`BookmarkEditDialog`,
  a pure input form reused for both the **+** button and the row's Edit action),
  and the empty/error state.
- `screens/` — `BookmarksScreen`, the tab hosted by `app/home_page.dart`.
  Tapping a row opens the saved link in an in-app browser view via
  `url_launcher`'s `launchUrl(..., mode: LaunchMode.inAppBrowserView)` (Custom
  Tabs on Android, `SFSafariViewController` on iOS).

Reads/writes are scoped to the caller's own `uid` by the document path, mirroring
the Firestore rules: the `users/{uid}/bookmarks/{bookmarkId}` match grants
`read, write` only to the owner of that `{uid}` segment. Unlike notifications
(written server-side by the webhook function), bookmarks are client-created — but
because ownership is structural, the rules don't have to inspect or pin a `uid`
field, and the newest-first query needs no composite index (an unfiltered
`orderBy('createdAt')` rides the automatic single-field index).
