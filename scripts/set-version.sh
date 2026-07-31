#!/bin/bash
# Bump the version everywhere a release touches, in one command:
#   build.sh                                  the app bundle (what the in-app updater compares)
#   plugins/claudewatch/.claude-plugin/plugin.json   the plugin manifest
#   .claude-plugin/marketplace.json           the catalog — Claude Code only offers plugin users
#                                             an update when the version here changes
# ponytail: three sed lines beat a build-time templating system for a file each release touches once.
set -e
cd "$(dirname "$0")/.."
V="$1"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/set-version.sh X.Y.Z"; exit 1; }
perl -pi -e "s{(CFBundleShortVersionString</key><string>)[^<]+}{\${1}$V}" build.sh
perl -pi -e "s{(\"version\": \")[^\"]+}{\${1}$V}" \
  plugins/claudewatch/.claude-plugin/plugin.json .claude-plugin/marketplace.json
grep -h "$V" build.sh plugins/claudewatch/.claude-plugin/plugin.json .claude-plugin/marketplace.json
