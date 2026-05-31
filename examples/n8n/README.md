# examples/n8n

Push a phone notification from any [n8n](https://n8n.io) workflow with an
[HTTP Request node](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.httprequest/)
— get pinged when an automation finishes, a scheduled job completes, or an error
branch fires.

See [../README.md](../README.md) for the shared payload contract.

## Add the HTTP Request node

Drop an **HTTP Request** node at the point in your workflow where you want the
notification to fire, then configure it:

| Setting               | Value                                                               |
| --------------------- | ------------------------------------------------------------------- |
| **Method**            | `POST`                                                              |
| **URL**               | `https://<region>-<project>.cloudfunctions.net/webhook/<userToken>` |
| **Authentication**    | `None` (the `userToken` in the URL is the routing key)              |
| **Send Headers**      | on → `Content-Type` = `application/json`                            |
| **Send Body**         | on → **Body Content Type** = `JSON`                                 |
| **Specify Body**      | `Using JSON`                                                        |

Keep the webhook URL private. Store it once in **Settings → Variables** (e.g.
`NOTIFYME_WEBHOOK_URL`) and reference it as the URL with
`{{ $vars.NOTIFYME_WEBHOOK_URL }}`, so it never leaks when you export or share
the workflow — rather than pasting it into every node.

## JSON body

Paste this into the node's JSON body field:

```json
{
  "title": "n8n workflow finished",
  "message": "Daily sync completed successfully.",
  "category": "n8n",
  "status": "success",
  "url": "https://your-n8n.example.com/workflow/42"
}
```

### Pull values from the run

n8n evaluates `{{ }}` expressions inside the JSON, so you can customize each
notification with the workflow name, execution details, or fields from earlier
nodes such as `{{ $json.status }}`:

```json
{
  "title": "n8n: {{ $workflow.name }}",
  "message": "Processed {{ $json.count }} records for {{ $json.customer }}.",
  "category": "n8n",
  "status": "success",
  "url": "{{ $execution.url }}"
}
```

`{{ $execution.url }}` deep-links the notification to this exact run, so tapping
it opens the execution in n8n.

## Success and failure notifications

For workflows with explicit branches, add one HTTP Request node to the success
branch and another to the failure branch — same configuration, different body.
For uncaught errors, build a dedicated error workflow that starts with an
**Error Trigger** node, set it under **Workflow Settings → Error Workflow**, and
have it POST with `status: "error"`:

```json
{
  "title": "❌ {{ $workflow.name }} failed",
  "message": "{{ $json.execution.error.message }}",
  "category": "n8n",
  "status": "error",
  "url": "{{ $execution.url }}"
}
```

Set `status` to match the result you want shown in NotifyMe: `success` for
green, `error` for red, `warning` for yellow, and `info` for blue.

## Recommended fields

| Field      | Required | Recommended value                                       |
| ---------- | -------- | ------------------------------------------------------- |
| `title`    | yes      | Short workflow outcome, such as `"n8n workflow failed"` |
| `message`  | yes      | Include the workflow name and what happened.            |
| `category` | no       | `"n8n"` (free-form; defaults to `general`)              |
| `status`   | no       | `success` \| `error` \| `warning` \| `info`             |
| `url`      | no       | `{{ $execution.url }}`, or a link to a dashboard/ticket |

`status` maps to a color in the app: `success`=green, `error`=red,
`warning`=yellow, `info`=blue.

> A 2xx response from the webhook means the notification was accepted. If the
> HTTP Request node reports a non-2xx status, check the `userToken` in the URL.
