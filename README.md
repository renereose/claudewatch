# claudewatch

> An always-on-top HUD for your live [Claude Code](https://claude.com/claude-code) sessions.

[![CI](https://github.com/renereose/claudewatch/actions/workflows/ci.yml/badge.svg)](https://github.com/renereose/claudewatch/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/renereose/claudewatch?sort=semver)](https://github.com/renereose/claudewatch/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS 12+](https://img.shields.io/badge/platform-macOS%2012%2B-lightgrey)

Run several Claude Code sessions at once and lose track of which one needs you?
**claudewatch** is a tiny floating widget that watches every live session and shows,
at a glance, which are working, which finished, and — most importantly — which are
**waiting for your input or permission**.

No server, no dependencies, no telemetry. It reads Claude Code's own local session
logs (`~/.claude/**`) directly and links only against system frameworks.

<p align="center">
  <img src="docs/list_view.png" alt="claudewatch list view — a session card showing status, activity, model and permission mode" width="420">
</p>

<table align="center">
<tr>
  <td align="center" width="50%">
    <img src="docs/bubble_view.png" alt="Bubble mode — compact one-line summary" width="240"><br>
    <sub><b>Bubble mode</b> — tuck it in a corner; glows amber when a session needs input.</sub>
  </td>
  <td align="center" width="50%">
    <img src="docs/settings_view.png" alt="Settings panel — opacity and toggles" width="240"><br>
    <sub><b>Settings</b> — opacity, pop-open-on-input, hide idle, float-above-all, compact.</sub>
  </td>
</tr>
</table>

## Features

- **Live status per session** — working · waiting-for-input · done · interrupted, updated every 2s.
- **"Needs you" alerts** — surfaces the exact wait reason (`input needed`, `dialog open`,
  permission prompts, plan review, open questions, …) straight from Claude Code's session state,
  and floats those sessions to the top.
- **Model & permission mode** — see which model each session runs and whether it's in
  `default`, `plan`, `auto-accept`, or `bypass` mode (color-coded).
- **Sub-agent tracking** — running vs. finished agents, including background agents.
- **Two modes** — a full **list** or a compact **bubble** you can tuck into a corner.
  The bubble glows amber the moment a session needs input.
- **Works with the IDE plugin** — sessions run from the **Cursor** / **VS Code** Claude Code
  extension are tracked alongside terminal sessions, with the same status, model, mode, and
  "needs you" alerts. A small **host badge** on each card names where a session runs
  (`terminal` / `iterm` / `warp` / `cursor` / `code` / …).
- **Click to focus** — click a session to jump to where it lives. Terminal tabs are selected
  exactly; IDE sessions raise the editor window on that workspace:

  | Host | Focus |
  |------|-------|
  | Terminal.app | Exact tab (by tty) |
  | iTerm2 | Exact tab (by tty) |
  | Warp | App brought to front¹ |
  | Cursor / VS Code | Editor window for the session's folder² |

  ¹ Warp exposes no tab-scripting API (no AppleScript dictionary, URL scheme only creates tabs),
  so per-tab focus isn't possible. Anything else falls back to Terminal.app.
  ² IDE plugin sessions have no tty; clicking re-opens the workspace folder, which raises the
  window already on it (or opens one if the folder was closed).
- **Multi-config aware** — automatically picks up every `~/.claude*` config dir
  (e.g. `CLAUDE_CONFIG_DIR` aliases).
- **Settings** — opacity, "pop open when input needed", hide idle sessions, float-above-all,
  compact view. Remembers its position and preferences.

## Install

### Download (recommended)

1. Grab `Claudewatch.zip` from the [latest release](https://github.com/renereose/claudewatch/releases/latest).
2. Unzip and drag **Claudewatch.app** to `/Applications`.
3. **First launch — clear Gatekeeper.** The app is ad-hoc signed, not notarized by Apple,
   so macOS blocks it on first open ("Apple could not verify…"). Allow it once, either way:

   **Terminal:**
   ```sh
   xattr -dr com.apple.quarantine /Applications/Claudewatch.app
   open /Applications/Claudewatch.app
   ```

   **or GUI:** try to open it, then go to System Settings → **Privacy & Security** →
   scroll down → **Open Anyway**.

The app needs no runtime — the binary links only macOS system frameworks. It contains no
telemetry and only reads your local `~/.claude` logs; the Gatekeeper prompt is purely because
the project isn't paying for Apple notarization.

> On first click-to-focus, macOS will also ask for **Automation** permission (to raise the terminal tab).

### Build it yourself

Don't want to trust a prebuilt binary? Build from source in one command — see [Build](#build) below.
A locally built app isn't quarantined, so it opens without the Gatekeeper prompt.

### Run from source

```sh
swift run claudewatch          # GUI, floating window
swift run claudewatch --dump   # print scanned sessions as JSON and exit
```

## Build

```sh
./build.sh
```

Produces `Claudewatch.app` and a shareable `Claudewatch.zip`. Requires the Xcode
Command Line Tools (`xcode-select --install`).

### Project layout

```
Sources/claudewatch/
  Transcript.swift    # parse one session's .jsonl into a row
  Scanner.swift       # discover live sessions + assemble rows (scan)
  WebUI.swift         # the embedded HTML/CSS/JS UI
  DragView.swift      # native drag handle for the borderless panel
  AppDelegate.swift   # window, JS bridge, refresh loop
  main.swift          # entry point (--dump + bootstrap)
Package.swift         # Swift package manifest
build.sh              # packages the .app bundle + zip
```

## How it works

Claude Code records each session under `~/.claude/projects/**/*.jsonl` and tracks live
process status in `~/.claude/sessions/<pid>.json`. claudewatch:

1. Finds live sessions by verifying the recorded PID is still running.
2. Reads the authoritative `status` / `waitingFor` fields for each one (busy · shell · idle · waiting).
3. Parses the transcript for the title, current activity, model, permission mode, and sub-agents.
4. Renders it all in a borderless floating panel and refreshes every 2 seconds.

Everything is local. Nothing leaves your machine.

## Requirements

- macOS 12 (Monterey) or later
- [Claude Code](https://claude.com/claude-code) installed and used on the same machine

## Contributing

PRs welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Good first issues are labeled
[`good first issue`](https://github.com/renereose/claudewatch/labels/good%20first%20issue).

## License

[MIT](LICENSE) — do what you like, no warranty.
