# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.1] - 2026-07-23

### Added
- Host badge on each card naming where the session runs — `terminal` / `iterm` / `warp` for
  terminals, `cursor` / `code` / `windsurf` / `insiders` for editor plugins. Editor focus now
  also covers Windsurf and VS Code Insiders.

## [1.1.0] - 2026-07-23

### Added
- Cursor / VS Code Claude Code plugin sessions are now first-class: clicking one raises the
  editor window on its workspace folder (IDE sessions have no terminal tty).

### Changed
- Interactive tool calls that block on you — `AskUserQuestion` and plan approval
  (`ExitPlanMode`) — now register as "needs you" (`input needed` / `plan review`) and float
  to the top, instead of showing as busy work.

## [1.0.1] - 2026-07-23

### Added
- Click-to-focus now detects the terminal owning each session: Terminal.app and iTerm2
  select the exact tab by tty; Warp is brought to the front (no tab-scripting API).

## [1.0.0] - 2026-07-23

First public release.

### Added
- Always-on-top floating HUD of live Claude Code sessions, refreshing every 2s.
- Per-session status: working · waiting-for-input · done · interrupted.
- "Needs you" alerts surfacing the exact wait reason (input needed, dialog open,
  permission prompts) from Claude Code's session state; waiting sessions sort to the top.
- Model and permission mode per session (`default` / `plan` / `auto-accept` / `bypass`), color-coded.
- Sub-agent tracking (running vs. finished, including background agents).
- **List** and **bubble** view modes; the bubble shows a one-line-per-session summary and
  glows amber when input is needed.
- Click a session to focus its Terminal tab.
- Auto-detection of every `~/.claude*` config directory.
- Settings: opacity, pop-open-when-input-needed, hide idle sessions, float-above-all,
  compact view. Window position and preferences persist across launches.

[Unreleased]: https://github.com/renereose/claudewatch/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/renereose/claudewatch/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/renereose/claudewatch/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/renereose/claudewatch/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/renereose/claudewatch/releases/tag/v1.0.0
