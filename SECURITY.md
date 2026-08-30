# Security Policy

Flowstate is a personal, single-maintainer open-source project, maintained
best-effort with no SLA on response time.

## Supported Versions

Only the latest `main` branch is supported. There is no auto-update channel;
to get a fix, pull `main` and rebuild/reinstall (`./scripts/make_app.sh`).
Older builds are not patched.

## Reporting a Vulnerability

Please report security issues privately rather than opening a public issue:

1. Go to this repository's **Security** tab.
2. Click **Report a vulnerability** to open a private GitHub Security Advisory.

Describe the issue, how to reproduce it, and its impact. As a best-effort
personal project, please allow reasonable time for a fix before any public
disclosure.

## Security Model

Flowstate is a local, single-user macOS dictation app:

- It requires macOS **Accessibility** (global hotkey, and optional auto-learn
  field read-back) and **Microphone** permissions.
- It spawns local inference servers (whisper.cpp / Kyutai / llama.cpp) bound
  to **loopback only**.
- Dictation content is sensitive: everything you speak is transcribed
  locally, and if you opt into the Groq engine, sent to Groq's cloud API.
  Treat dictated content accordingly.
