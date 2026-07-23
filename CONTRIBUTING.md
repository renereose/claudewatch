# Contributing to claudewatch

Thanks for helping out! This is a small, deliberately dependency-free project — the
guiding principle is **the laziest solution that actually works**: stdlib and native
platform features before new code, the shortest working diff over cleverness.

## Ground rules

- **No new dependencies.** claudewatch links only against macOS system frameworks
  (`Cocoa`, `WebKit`). Keep it that way — it's what makes the app a single, share-anywhere binary.
- **Match the style.** Terse, commented where intent isn't obvious, no speculative abstractions.

### Where things live

| File | Responsibility |
|------|----------------|
| `Sources/claudewatch/Transcript.swift`  | Parse one session's `.jsonl` into a row (the Claude Code log format lives here). |
| `Sources/claudewatch/Scanner.swift`     | Discover live sessions on disk + assemble rows (`scan()`). |
| `Sources/claudewatch/WebUI.swift`       | The entire UI — an embedded HTML/CSS/JS document. |
| `Sources/claudewatch/DragView.swift`    | Native drag handle for the borderless panel. |
| `Sources/claudewatch/AppDelegate.swift` | Window, JS bridge, refresh loop. |
| `Sources/claudewatch/main.swift`        | Entry point (`--dump` + app bootstrap). |

## Dev loop

```sh
# Run it (SwiftPM builds + launches the GUI)
swift run claudewatch

# Sanity-check the scanner without the GUI (also the built-in self-test)
swift run claudewatch --dump

# Produce the distributable app + zip
./build.sh
```

`--dump` prints the scanned sessions as JSON and exits non-zero if scanning breaks, so
it doubles as a smoke test.

## Submitting a change

1. Fork and create a branch (`fix/…` or `feat/…`).
2. Make your change; verify both `swift claudewatch.swift --dump` and `./build.sh` succeed.
3. Test the GUI manually with at least one live Claude Code session running.
4. Open a PR using the template. Describe what you changed and how you verified it.
   Screenshots/GIFs are hugely appreciated for any UI change.

## Reporting bugs / ideas

Use the [issue templates](https://github.com/renereose/claudewatch/issues/new/choose).
For bugs, include your macOS version and the output of `swift run claudewatch --dump`
(redact anything sensitive — it may contain session titles/paths).

## Releasing (maintainers)

Releases are automated. Tag a semver version and push it:

```sh
git tag v1.2.3
git push origin v1.2.3
```

The [release workflow](.github/workflows/release.yml) builds `Claudewatch.app`, zips it,
and publishes a GitHub Release with the zip attached. Update [CHANGELOG.md](CHANGELOG.md)
before tagging.
