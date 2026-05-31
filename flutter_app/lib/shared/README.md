# shared/

Cross-feature code: models, constants, theming helpers, and small widgets
used by more than one feature. Keep this dependency-light — `shared/` may
not import from `features/`.

- `notification_status.dart` — the `status` → color contract shared by the
  webhook payload, the inbox, and the docs.
