---
type: skill
name: google-workspace
title: google-workspace
description: Gmail, Calendar, Drive, Docs, Sheets via gws CLI, ADC credentials, or Google Workspace Manager.
tags: [Google, Workspace, Gmail, Calendar, Drive, Sheets, Docs, Email, OAuth]
upstream: https://github.com/NousResearch/hermes-agent/tree/main/skills/productivity/google-workspace
version: 1.1.0
timestamp: 2026-07-25
---

# Google Workspace

Gmail, Calendar, Drive, Contacts, Sheets, and Docs — imported by reference from NousResearch/hermes-agent (`skills/productivity/google-workspace`) and adapted for Iris.

> **Upstream Reference**: [NousResearch/hermes-agent: google-workspace](https://github.com/NousResearch/hermes-agent/tree/main/skills/productivity/google-workspace)

In Iris, Google Workspace capabilities are accessible through native `google_*` tools (`google_calendar_list_events`, `google_docs_get`, `google_drive_search`, etc.), via Application Default Credentials (ADC), or via the `gws` CLI wrapper / Python API.

## Built-in Iris Integration

Iris includes native OAuth2 & ADC credential management (`ADCCredentialManager`) and built-in Google Workspace tools.

### Available Built-in Tools:
- `google_calendar_list_events`: List upcoming events from primary Google Calendar.
- `google_calendar_create_event`: Create an event in primary Google Calendar.
- `google_docs_get`: Fetch Google Document content by ID.
- `google_drive_search`: Search Google Drive files with queries.

## Upstream Hermes Setup Workflow

If executing via Python scripts or `gws` CLI:

```bash
GSETUP="python ~/.iris/memory/skills/google-workspace/scripts/setup.py"
```

### Step 0: Check Authentication Status

```bash
$GSETUP --check
```

### Step 1: OAuth2 Credentials

1. Create a project in Google Cloud Console.
2. Enable target APIs: Gmail API, Google Calendar API, Google Drive API, Google Sheets API, Google Docs API, People API.
3. Create OAuth 2.0 Client ID (Application type: "Desktop app").
4. Provide the client secret JSON path:

```bash
$GSETUP --client-secret /path/to/client_secret.json
```

### Step 2: Get Authorization URL

```bash
$GSETUP --auth-url --services all --format json
```

Complete the OAuth flow in the browser and provide the redirect code/URL.
