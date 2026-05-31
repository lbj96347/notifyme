# examples/claude-code

Notify your phone when a [Claude Code](https://claude.com/claude-code) job
finishes — green on success, red on failure — so you can walk away from a
long-running session and get pinged when it's done.

See [../README.md](../README.md) for the shared payload contract.

## Quick start

Set your personal webhook URL once, then `curl` it from anywhere Claude Code runs:

```bash
export WEBHOOK_URL="https://<region>-<project>.cloudfunctions.net/webhook/<userToken>"

curl -fsS -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Claude Code finished",
    "message": "Refactor + tests complete on feature/auth.",
    "category": "claude",
    "status": "success",
    "url": "https://github.com/me/repo/pull/42"
  }'
```

- `-f` makes `curl` exit non-zero on HTTP errors (so a failed notify is visible).
- `-sS` stays quiet but still prints errors.
- Set `url` to the PR, branch, or session you want to jump to when you tap the
  notification.

## Notify on success and failure

Run Claude Code as a command and notify with the `status` (and color) that matches
the outcome. Drop this in a shell script and run your task through it:

```bash
#!/usr/bin/env bash
set -euo pipefail

WEBHOOK_URL="${WEBHOOK_URL:?set WEBHOOK_URL to your NotifyMe webhook URL}"

notify() {
  # notify <status> <title> <message> [url]
  local status="$1" title="$2" message="$3" url="${4:-}"
  curl -fsS -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$(cat <<JSON
{
  "title": $(jq -Rn --arg s "$title"   '$s'),
  "message": $(jq -Rn --arg s "$message" '$s'),
  "category": "claude",
  "status": "$status",
  "url": "$url"
}
JSON
)" >/dev/null || echo "notifyme: failed to send notification" >&2
}

# Notify on failure no matter where the script exits.
trap 'notify error "Claude Code failed" "Run exited at line $LINENO."' ERR

# ---- run Claude Code non-interactively ----
claude -p "Fix the failing tests in src/, then run the suite and report results."
# -------------------------------------------

notify success "Claude Code finished" "Task completed and the suite is green." \
  "https://github.com/me/repo"
```

`claude -p "<prompt>"` runs Claude Code in headless (print) mode and exits when the
task is done, which is what makes the success/failure notification fire at the right
time. Using `jq -Rn` to build the JSON keeps titles and messages safe when they
contain quotes or newlines. If you don't have `jq`, keep `title`/`message` simple and
inline them as in the Quick start example.

## Notify from a hook

Claude Code can fire the webhook itself via a [Stop hook](https://docs.claude.com/en/docs/claude-code/hooks),
so every session pings your phone when it ends — no wrapper script needed. Add this
to `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -fsS -X POST \"$WEBHOOK_URL\" -H 'Content-Type: application/json' -d '{\"title\":\"Claude Code session ended\",\"message\":\"Your Claude Code session has stopped.\",\"category\":\"claude\",\"status\":\"info\"}'"
          }
        ]
      }
    ]
  }
}
```

Export `WEBHOOK_URL` in the environment Claude Code runs in. The Stop hook can't know
whether the underlying task "passed," so it sends `status: info` (blue); use the
wrapper-script pattern above when you want success/error coloring.

## Fields

| Field      | Required | Example                                          |
| ---------- | -------- | ------------------------------------------------ |
| `title`    | yes      | `"Claude Code finished"`                         |
| `message`  | yes      | `"Refactor + tests complete on feature/auth."`   |
| `category` | no       | `"claude"` (free-form; defaults to `general`)    |
| `status`   | no       | `success` \| `error` \| `warning` \| `info`      |
| `url`      | no       | `"https://github.com/me/repo/pull/42"`           |

`status` maps to a color in the app: `success`=green, `error`=red, `warning`=yellow,
`info`=blue.
