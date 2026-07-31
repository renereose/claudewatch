#!/bin/bash
# One-time Gatekeeper approval for Claudewatch.app, then launch it.
# The app is ad-hoc signed (not Apple-notarized), so macOS quarantines it on first download.
# This is the same `xattr` line the README asks you to run by hand — it only ever touches
# Claudewatch.app, and only when you invoke it. It is deliberately NOT wired to a hook.
APP=""
for p in /Applications/Claudewatch.app "$HOME/Applications/Claudewatch.app"; do
  [ -d "$p" ] && APP="$p" && break
done
if [ -z "$APP" ]; then
  echo "Claudewatch.app not found in /Applications or ~/Applications."
  echo "Download it from https://github.com/renereose/claudewatch/releases/latest and drag it there first."
  exit 1
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
  echo "Could not clear the quarantine flag on $APP (owned by another user?)."
  echo "Try: sudo xattr -dr com.apple.quarantine \"$APP\""
  exit 1
fi
open "$APP" && echo "Approved and launched $APP — the SessionStart hook can start it silently from now on."
