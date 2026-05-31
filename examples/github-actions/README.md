# examples/github-actions

Notify your phone when a [GitHub Actions](https://docs.github.com/actions)
workflow finishes — green on success, red on failure — so you can walk away from
a long CI run and get pinged when it's done.

See [../README.md](../README.md) for the shared payload contract.

## Setup

Store your personal webhook URL as a repository secret so it never appears in
logs or workflow files:

1. Repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.
2. Name it `NOTIFYME_WEBHOOK_URL`.
3. Value:
   `https://<region>-<project>.cloudfunctions.net/webhook/<userToken>`.

Reference it in steps as `${{ secrets.NOTIFYME_WEBHOOK_URL }}`.

## Quick start

A single step that pings you when the job reaches it:

```yaml
- name: Notify NotifyMe
  run: |
    curl -fsS -X POST "$NOTIFYME_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d '{
        "title": "CI finished",
        "message": "Build completed on '"$GITHUB_REF_NAME"'.",
        "category": "github-actions",
        "status": "success",
        "url": "'"$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"'"
      }'
  env:
    NOTIFYME_WEBHOOK_URL: ${{ secrets.NOTIFYME_WEBHOOK_URL }}
```

- `-f` makes `curl` exit non-zero on HTTP errors, so a failed notify shows up
  as a failed step.
- `$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID` is the URL
  of this run — tap the notification to jump straight to the logs.

## Notify on success and failure

Add two steps at the end of your job, each gated on the job's outcome so exactly
one fires. `if: success()` / `if: failure()` evaluate the status of the steps
that ran before them.

```yaml
name: CI

on: [push]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # ---- your real build/test steps ----
      - name: Run tests
        run: make test
      # -------------------------------------

      - name: Notify success
        if: success()
        run: |
          curl -fsS -X POST "$NOTIFYME_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d '{
              "title": "✅ CI passed",
              "message": "'"$GITHUB_WORKFLOW"' succeeded on '"$GITHUB_REF_NAME"'.",
              "category": "github-actions",
              "status": "success",
              "url": "'"$RUN_URL"'"
            }'
        env:
          NOTIFYME_WEBHOOK_URL: ${{ secrets.NOTIFYME_WEBHOOK_URL }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}

      - name: Notify failure
        if: failure()
        run: |
          curl -fsS -X POST "$NOTIFYME_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d '{
              "title": "❌ CI failed",
              "message": "'"$GITHUB_WORKFLOW"' failed on '"$GITHUB_REF_NAME"'.",
              "category": "github-actions",
              "status": "error",
              "url": "'"$RUN_URL"'"
            }'
        env:
          NOTIFYME_WEBHOOK_URL: ${{ secrets.NOTIFYME_WEBHOOK_URL }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
```

`if: failure()` only runs when an earlier step failed, so the red notification
fires for real failures while the green one is skipped — and vice versa. Use
`if: always()` instead if you want a step to run regardless of outcome.

## Fields

| Field      | Required | Example                                               |
| ---------- | -------- | ----------------------------------------------------- |
| `title`    | yes      | `"✅ CI passed"`                                       |
| `message`  | yes      | `"CI succeeded on main."`                             |
| `category` | no       | `"github-actions"` (free-form; defaults to `general`) |
| `status`   | no       | `success` \| `error` \| `warning` \| `info`           |
| `url`      | no       | the Actions run URL (see above)                       |

`status` maps to a color in the app: `success`=green, `error`=red, `warning`=yellow,
`info`=blue.
