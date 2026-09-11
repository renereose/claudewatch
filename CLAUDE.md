# claudewatch

## Releasing — always bump all three versions together

The version lives in three files that MUST stay in sync:

- `build.sh` — app bundle (`CFBundleShortVersionString`); the in-app updater compares this to the GitHub release tag.
- `plugins/claudewatch/.claude-plugin/plugin.json` — plugin manifest.
- `.claude-plugin/marketplace.json` — catalog; Claude Code only offers plugin users an update when the version here changes.

**Never hand-edit one.** Bump all three at once:

```
scripts/set-version.sh X.Y.Z
git commit -am "release: X.Y.Z"
git tag vX.Y.Z && git push --tags   # release.yml builds + publishes on the tag
```

If the tag (vX.Y.Z) is ahead of `plugin.json`/`marketplace.json`, users get a "plugin update"
banner that never clears — the app compares the tag against the installed plugin, but the
marketplace still advertises the old version, so the update can't actually be applied. That is
exactly what happened with 1.7.0 (app bumped, plugin/marketplace left at 1.6.0).
