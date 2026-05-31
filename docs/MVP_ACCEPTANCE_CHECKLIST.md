# MVP Acceptance Checklist

End-to-end acceptance checks for the NotifyMe MVP. Run this top-to-bottom on a
real build pointed at a real Firebase project before calling a release "done."
Every step has an **Action** (what you do) and **Expected** (what proves it
passed). Check the box only when *Expected* is observed — not when the action
merely completes without error.

This validates the core product flow:

```
sign in → create token → copy URL → POST webhook → Firestore doc → FCM push
        → open app → view detail → search → mark read → mark all read
```

## Prerequisites

Before starting, the backend and a build must already be in place. See
[`DEPLOYMENT.md`](./DEPLOYMENT.md) for the build→deploy→verify loop and
[`FIREBASE_SETUP.md`](./FIREBASE_SETUP.md) for one-time project setup.

- [ ] The `webhook` Cloud Function is deployed; you have its base URL
      (`https://<region>-<project>.cloudfunctions.net/webhook` or the Hosting
      rewrite, e.g. `https://<project>.web.app/webhook`).
- [ ] Firestore security rules and indexes are deployed.
- [ ] A debug/release app build is installed on a **physical** device
      (push delivery does not work on plain emulators/simulators without a
      configured push setup — use a real phone for the FCM steps).
- [ ] On iOS, an APNs key is uploaded to Firebase Cloud Messaging.
- [ ] You can read Firestore in the Firebase Console and tail logs with
      `firebase functions:log`.
- [ ] You have a clean test account (or can delete and recreate one) so the
      inbox starts empty.

Record the environment under test:

| Field | Value |
|-------|-------|
| Project ID | |
| Function base URL | |
| App version / build | |
| Test device (model + OS) | |
| Tester / date | |

---

## 1. Sign in

- [ ] **Action:** Launch the app on a fresh install. **Expected:** You land on
      the auth screen, not the inbox (the auth gate blocks unauthenticated
      users).
- [ ] **Action:** Sign in with the test account. **Expected:** Sign-in succeeds
      and the app navigates to the inbox.
- [ ] **Action:** Open the Firebase Console → Authentication. **Expected:** The
      test account appears in the users list.
- [ ] **Action:** Open Firestore → `users`. **Expected:** A `users/{uid}`
      document exists with `uid` and `email` matching the signed-in account.
- [ ] **Action:** Confirm the device registered for push. **Expected:** A
      `devices` document exists with this account's `uid`, a non-empty
      `fcmToken`, and the correct `platform`. *(This is what lets the webhook
      deliver a push later — do not skip it.)*

> If no `devices` doc appears, the app did not obtain/persist an FCM token
> (often a missing push permission on iOS, or notifications denied). Resolve
> before continuing — without a device token the webhook still returns `201`
> (the notification is persisted), but no push is delivered.

## 2. Create a webhook token

- [ ] **Action:** Go to the webhook/token screen. **Expected:** A personal
      webhook token + URL is shown (creating one on first visit if needed).
- [ ] **Action:** Open Firestore → `users/{uid}`. **Expected:** The user
      document carries a `webhookToken` field holding a long, url-safe random
      string. *(The token is stored on the user doc, not in a separate
      collection — the function resolves it with a `where("webhookToken","==",…)`
      query. It is the routing key, not a password.)*

## 3. Copy the webhook URL

- [ ] **Action:** Tap **Copy** on the webhook URL. **Expected:** A confirmation
      (snackbar/toast) appears and the clipboard holds the full URL.
- [ ] **Action:** Paste the URL somewhere to inspect it. **Expected:** It has
      the shape `…/webhook/{token}` and `{token}` matches the `webhookToken`
      field on `users/{uid}` from step 2.

## 4. Send a webhook (curl)

Use the copied URL. The payload contract is
`{ title, message, category, status, url }` — `title` and `message` are
required; `status` ∈ `success | error | warning | info`; `url` (optional) must
start with `http://` or `https://`. See [`examples/`](../examples/) for
copy-paste senders.

```bash
curl -i -X POST "<PASTE_WEBHOOK_URL>" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Acceptance test",
    "message": "End-to-end MVP check",
    "category": "claude",
    "status": "success",
    "url": "https://example.com/pr/123"
  }'
```

- [ ] **Action:** Send the request above. **Expected:** HTTP `201` with body
      `{"ok":true,"id":"…"}`. The push is best-effort and fire-and-forget — the
      response does **not** report delivery; confirm the actual push in step 6
      and the delivered count via logs (`firebase functions:log` shows
      `pushed notification { id, … }`).
- [ ] **Action (negative — missing field):** Re-send with `message` removed.
      **Expected:** HTTP `400` with body
      `{"ok":false,"error":"invalid payload","details":[…]}` whose `details`
      mention `message`.
- [ ] **Action (negative — bad status):** Re-send with `"status":"bogus"`.
      **Expected:** HTTP `400`; `details` contains
      `status must be one of: success, error, warning, info`.
- [ ] **Action (negative — wrong token):** POST to `…/webhook/not-a-real-token`.
      **Expected:** HTTP `404` `{"ok":false,"error":"unknown webhook token"}`
      (malformed and unknown tokens are indistinguishable by design).
- [ ] **Action (negative — wrong method):** `curl -i <WEBHOOK_URL>` (GET).
      **Expected:** HTTP `405` `{"ok":false,"error":"method not allowed; use POST"}`
      with an `Allow: POST` header.

## 5. Notification written to Firestore

- [ ] **Action:** Open Firestore → `notifications`. **Expected:** A new document
      exists from the step-4 `201` call, with: `uid` = your uid, `title` =
      "Acceptance test", `message`, `category: "claude"`, `status: "success"`,
      `url` set, `read: false`, and a server `createdAt` timestamp.
- [ ] **Action:** Confirm scoping. **Expected:** The doc's `uid` matches the
      signed-in account (notifications are isolated per user by security rules).

## 6. Receive the push

- [ ] **Action:** With the app **backgrounded or closed**, send another webhook
      (step 4). **Expected:** A system push notification arrives on the device
      showing the `title` and `message`.
- [ ] **Action:** Send one with `"status":"error"`. **Expected:** Push arrives;
      in-app the item carries the error (red) status color.
- [ ] **Action (optional):** Tail logs with `firebase functions:log`.
      **Expected:** The webhook invocation logged a successful multicast send
      with no FCM errors.

> If the Firestore doc is created (step 5) but no push arrives, the failure is
> in delivery, not the webhook: re-check the `devices` token, iOS APNs key, and
> that notifications are permitted on the device.

## 7. Open the app

- [ ] **Action:** Tap the push notification. **Expected:** The app opens to the
      relevant notification (its detail), not a blank/cold inbox.
- [ ] **Action:** Open the app normally and view the inbox. **Expected:** The
      test notifications appear, **grouped by day**, with status colors
      (green = success, red = error, yellow = warning, blue = info). Unread
      items are visibly distinct from read ones.

## 8. View notification detail

- [ ] **Action:** Tap a notification in the inbox. **Expected:** A detail view
      opens showing the full `title`, `message`, `category`, and `status`.
- [ ] **Action:** Confirm the `url` is actionable. **Expected:** The detail
      shows a tappable link that opens `https://example.com/pr/123` (the `url`
      from step 4) in a browser.
- [ ] **Action:** Open a notification sent **without** a `url`. **Expected:** The
      detail renders cleanly with no broken/empty link affordance.

## 9. Search

- [ ] **Action:** Open search and type a term present in a test notification
      (e.g. `Acceptance`). **Expected:** Matching notifications are shown.
- [ ] **Action:** Search a term that exists in only one item. **Expected:** Only
      that item is returned.
- [ ] **Action:** Search a string that matches nothing. **Expected:** An empty
      result / "no results" state, not a crash or the full list.
- [ ] **Action:** Clear the search. **Expected:** The full inbox returns,
      still grouped by day.

## 10. Mark read

- [ ] **Action:** Open an unread notification (or use its mark-read control).
      **Expected:** It changes to the read state in the inbox.
- [ ] **Action:** Open Firestore → that `notifications` doc. **Expected:**
      `read` flipped to `true`.
- [ ] **Action:** Background and reopen the app. **Expected:** The item is still
      read (state persisted, not just local).

## 11. Mark all read

- [ ] **Action:** Ensure at least two unread notifications exist (send more
      webhooks if needed), then tap **Mark all read**. **Expected:** Every item
      shows the read state; no unread indicator remains.
- [ ] **Action:** Open Firestore → `notifications`. **Expected:** All of this
      user's docs now have `read: true`.
- [ ] **Action:** Send one more webhook. **Expected:** It arrives as **unread**
      (mark-all-read affected existing items only, not future ones).

---

## Sign-off

The MVP passes acceptance only when **every** box above is checked on the
recorded environment.

- [ ] All sections 1–11 pass.
- [ ] Negative cases in section 4 behaved as specified.
- [ ] No errors in `firebase functions:log` during the run.

| | |
|---|---|
| Result | ☐ Pass ☐ Fail |
| Tester | |
| Date | |
| Notes / defects filed | |
