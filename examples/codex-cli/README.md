# examples/codex-cli

Notify your phone when a [Codex CLI](https://developers.openai.com/codex/cli)
task finishes — green on success, red on failure — so you can step away from a
long-running run and get pinged when it's done.

See [../README.md](../README.md) for the shared payload contract.

## Quick start

Set your personal webhook URL once, then `curl` it from anywhere Codex CLI runs:

```bash
export WEBHOOK_URL="https://<region>-<project>.cloudfunctions.net/webhook/<userToken>"

curl -fsS -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Codex task finished",
    "message": "Implemented the API client and tests passed.",
    "category": "codex",
    "status": "success",
    "url": "https://github.com/me/repo/pull/42"
  }'
```

- `-f` makes `curl` exit non-zero on HTTP errors (so a failed notify is visible).
- `-sS` stays quiet but still prints errors.
- Set `url` to the PR, branch, or session you want to jump to when you tap the
  notification.

## Notify on success and failure

Run Codex CLI non-interactively and notify with the `status` (and color) that
matches the outcome. Drop this in a shell script and run your task through it:

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
  "category": "codex",
  "status": "$status",
  "url": "$url"
}
JSON
)" >/dev/null || echo "notifyme: failed to send notification" >&2
}

# Notify on failure no matter where the script exits.
trap 'notify error "Codex task failed" "Run exited at line $LINENO."' ERR

# ---- run Codex CLI non-interactively ----
codex exec "Implement the API client in src/, then run the test suite."
# -----------------------------------------

notify success "Codex task finished" "Task completed and the suite is green." \
  "https://github.com/me/repo"
```

`codex exec "<prompt>"` runs Codex CLI in non-interactive (automation) mode and
exits when the task is done, which is what makes the success/failure notification
fire at the right time. Using `jq -Rn` to build the JSON keeps titles and messages
safe when they contain quotes or newlines. If you don't have `jq`, keep
`title`/`message` simple and inline them as in the Quick start example.

## Fields

| Field      | Required | Example                                          |
| ---------- | -------- | ------------------------------------------------ |
| `title`    | yes      | `"Codex task finished"`                          |
| `message`  | yes      | `"Implemented the API client and tests passed."` |
| `category` | no       | `"codex"` (free-form; defaults to `general`)     |
| `status`   | no       | `success` \| `error` \| `warning` \| `info`      |
| `url`      | no       | `"https://github.com/me/repo/pull/42"`           |

`status` maps to a color in the app: `success`=green, `error`=red, `warning`=yellow,
`info`=blue.
