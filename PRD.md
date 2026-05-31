This is actually a very useful open-source project. I can see myself using it for:

* Claude Code
* Codex CLI
* OpenAI Agents
* n8n
* GitHub Actions
* Jenkins
* Long-running Python scripts
* VPS monitoring
* AI video generation jobs
* SEO crawling jobs

The key idea is:

“Give every developer a personal webhook URL that can instantly push notifications to their phone.”

Think of it as a self-hosted alternative to:

* Pushover
* ntfy
* Pushbullet
* Bark
* Telegram Bot notifications

but built on Flutter + Firebase.

⸻

PRD — NotifyMe

Product Overview

Product Name

NotifyMe

Tagline

Receive webhook notifications instantly on your phone.

Vision

Allow developers, AI agent users, and automation builders to receive real-time notifications from any system via webhook.

Users deploy the open-source stack into their own Firebase project and receive push notifications on iOS and Android.

⸻

Problem Statement

Developers frequently run long-running tasks:

* Claude Code
* Codex CLI
* Cursor Agent
* GitHub Actions
* n8n workflows
* Docker jobs
* AI video generation
* SEO crawling

They constantly need to check:

Is it finished?
Did it fail?
What happened?

Current solutions:

* Email
* Slack
* Discord
* Telegram

are too heavy.

Users simply want:

POST webhook
→ Phone notification
→ Open app
→ View details

⸻

Target Audience

Primary

Developers

Secondary

DevOps Engineers

Tertiary

AI Agent Users

Especially:

* Claude Code users
* Codex CLI users
* Cursor users
* n8n users

⸻

MVP Features

Feature 1 — Personal Webhook Endpoint

Every user gets:

https://<project>.cloudfunctions.net/webhook/{userToken}

Example:

https://notifyme.app/api/webhook/abc123

⸻

POST Request

{
  "title": "Claude Code Finished",
  "message": "Feature completed successfully",
  "category": "claude",
  "status": "success"
}

⸻

Feature 2 — Push Notification

When webhook arrives:

Webhook
↓
Firebase Function
↓
Firestore
↓
FCM Push
↓
User Phone

Notification:

Claude Code Finished
Feature completed successfully

⸻

Feature 3 — Notification Inbox

Inside app:

Today
✓ Claude Code Finished
✓ Deployment Successful
✗ Unit Test Failed
Yesterday
✓ SEO Crawl Completed

⸻

Feature 4 — Categories

Categories help organize notifications.

Examples:

AI Agent
DevOps
Deployment
GitHub
Monitoring
Personal

⸻

Category Colors

Green
Success
Red
Error
Yellow
Warning
Blue
Info

⸻

Feature 5 — Search

Search:

deployment

Result:

Deployment Successful
Deployment Failed
Deployment Started

⸻

Feature 6 — Read / Unread

Support:

Mark Read
Mark All Read

⸻

User Flow

Initial Setup

Install App

↓

Sign In

↓

Create Device

↓

Receive Webhook URL

↓

Copy URL

↓

Done

⸻

Receiving Notification

Claude Code

↓

Webhook POST

↓

Firebase Function

↓

Firestore

↓

FCM

↓

Phone Notification

↓

Open App

↓

View Detail

⸻

Technical Architecture

Flutter
│
├── Firebase Auth
├── Firestore
├── Firebase Messaging
├── Firebase Functions
└── Firebase Analytics
Cloud Function
│
└── Receive Webhook
Firestore
│
├── Users
├── Devices
└── Notifications

⸻

Firestore Schema

users

{
  "uid": "xxx",
  "email": "user@email.com",
  "createdAt": "..."
}

⸻

devices

{
  "uid": "xxx",
  "fcmToken": "...",
  "platform": "ios"
}

⸻

notifications

{
  "uid": "xxx",
  "title": "Claude Code Finished",
  "message": "Feature completed",
  "category": "claude",
  "status": "success",
  "read": false,
  "createdAt": "..."
}

⸻

Future Features (v2)

Notification Rules

If category = deployment
→ High Priority
If status = error
→ Critical Alert

⸻

Webhook Secret Verification

Authorization: Bearer xxx

Prevent abuse.

⸻

Multiple Projects

Project A
Project B
Project C

Useful for agencies and consultants.

⸻

Team Sharing

Webhook
↓
Notify 5 people

⸻

Claude Code Integration

Provide a ready-made shell command:

curl -X POST "$WEBHOOK_URL" \
-H "Content-Type: application/json" \
-d '{
  "title":"Claude Finished",
  "message":"Task completed"
}'

⸻

Codex CLI Integration

curl -X POST "$WEBHOOK_URL" \
-H "Content-Type: application/json" \
-d '{
  "title":"Codex Finished",
  "message":"Migration complete"
}'

⸻

Open Source Goals

Repository Structure:

notifyme/
├── flutter_app/
├── firebase_functions/
├── docs/
├── examples/
│   ├── claude-code/
│   ├── codex-cli/
│   ├── n8n/
│   ├── github-actions/
│   └── bash/

License:

MIT

⸻

One enhancement I’d strongly recommend based on your workflow with Claude Code, Codex CLI, OpenClaw, and long-running agents:

Add “Session URL” and “Action Button” support in the notification payload.

Example:

{
  "title": "Claude Finished",
  "message": "Feature branch ready",
  "url": "https://github.com/project/pull/123",
  "category": "claude",
  "status": "success"
}

When you tap the notification, it can open:

* GitHub PR
* Claude session URL
* OpenClaw dashboard
* Local web dashboard
* VPS monitoring page

This turns NotifyMe from a simple push app into a lightweight AI-agent operations center.
