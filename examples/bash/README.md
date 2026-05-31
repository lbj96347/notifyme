# examples/bash

Send a NotifyMe notification with plain `curl` from any shell script.

See [../README.md](../README.md) for the shared payload contract.

## Quick start

Set your personal webhook URL once, then `curl` it:

```bash
export WEBHOOK_URL="https://<region>-<project>.cloudfunctions.net/webhook/<userToken>"

curl -fsS -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Build finished",
    "message": "Deploy to production succeeded in 4m12s.",
    "category": "bash",
    "status": "success",
    "url": "https://github.com/me/repo/actions/runs/123"
  }'
```

- `-f` makes `curl` exit non-zero on HTTP errors (so a failed notify fails your script).
- `-sS` stays quiet but still prints errors.

## In a long-running script

Wrap the `curl` in a helper and notify on both success and failure. This pattern
sends one notification when the job ends, with the `status` (and color) reflecting
the outcome.

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
  "category": "bash",
  "status": "$status",
  "url": "$url"
}
JSON
)" >/dev/null || echo "notifyme: failed to send notification" >&2
}

# Notify on failure no matter where the script exits.
trap 'notify error "Job failed" "Script exited at line $LINENO."' ERR

# ---- your long-running work here ----
echo "Running the long job..."
sleep 5
# --------------------------------------

notify success "Job finished" "The long job completed successfully." "https://example.com/dashboard"
```

Using `jq -Rn` to build the JSON keeps titles and messages safe when they contain
quotes, newlines, or other characters that would otherwise break the payload. If you
don't have `jq`, keep `title`/`message` simple and inline them as in the Quick start
example above.

## Fields

| Field      | Required | Example                                          |
| ---------- | -------- | ------------------------------------------------ |
| `title`    | yes      | `"Build finished"`                               |
| `message`  | yes      | `"Deploy to production succeeded in 4m12s."`     |
| `category` | no       | `"bash"` (free-form; defaults to `general`)      |
| `status`   | no       | `success` \| `error` \| `warning` \| `info`      |
| `url`      | no       | `"https://github.com/me/repo/actions/runs/123"`  |

`status` maps to a color in the app: `success`=green, `error`=red, `warning`=yellow,
`info`=blue.
