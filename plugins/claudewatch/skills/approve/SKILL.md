---
description: Clear the one-time macOS Gatekeeper quarantine on Claudewatch.app and launch it. Use when claudewatch won't open because "Apple could not verify" it, or right after installing the app.
disable-model-invocation: true
---

Run `${CLAUDE_PLUGIN_ROOT}/hooks/approve.sh` with the Bash tool and report its output verbatim.

The script clears `com.apple.quarantine` on Claudewatch.app (the app is ad-hoc signed, not
Apple-notarized) and then opens it. If it reports the app is missing, point the user at
https://github.com/renereose/claudewatch/releases/latest. If it reports it could not clear the
flag, give them the `sudo` command it printed — do not run `sudo` yourself.
