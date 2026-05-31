# examples

Copy-paste webhook senders for NotifyMe. Each subdirectory shows how to POST to
your personal webhook URL from a different tool or runtime.

All examples send the shared payload contract:

```json
{ "title": "...", "message": "...", "category": "claude", "status": "success", "url": "https://..." }
```

| Field      | Required | Notes                                                               |
| ---------- | -------- | ------------------------------------------------------------------- |
| `title`    | yes      | Notification headline.                                              |
| `message`  | yes      | Notification body.                                                  |
| `category` | no       | Organizes the inbox. Free-form; defaults to `general` when omitted. |
| `status`   | no       | One of `success`, `error`, `warning`, `info`. Defaults to `info`.   |
| `url`      | no       | `http(s)` deep link; makes the notification tappable.               |

**`status`** is a closed set, each mapped to a color in the app:

| `status`  | Color  |
| --------- | ------ |
| `success` | green  |
| `error`   | red    |
| `warning` | yellow |
| `info`    | blue   |

**`category`** is free-form — send any short label. The well-known categories
the examples below use are `claude`, `codex`, `ci`, `github-actions`, `n8n`,
`bash`, and `general`.

- [`claude-code/`](claude-code/) — notify when a Claude Code job finishes
- [`codex-cli/`](codex-cli/) — notify when a Codex CLI task finishes
- [`n8n/`](n8n/) — n8n HTTP Request node
- [`github-actions/`](github-actions/) — CI workflow step
- [`bash/`](bash/) — plain `curl` from a shell script

> Any change to the payload contract must be reflected in every example here.
