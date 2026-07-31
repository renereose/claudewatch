#!/bin/bash
# Bring up the claudewatch HUD when a Claude Code session starts, if it isn't already running.
# ponytail: nothing to install and nothing to download — if the app isn't on this Mac we just
# exit quietly, so the hook is a no-op instead of an error the user has to go silence.
pgrep -qx claudewatch || open -gb com.claudewatch.hud 2>/dev/null
exit 0
