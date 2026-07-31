# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2026-07-31

### Added
- **Custom sound when a session needs you** — pick any audio file (mp3, wav, aiff, m4a) in
  Settings and it plays the moment a session flips to "needs you". Works on its own, without
  enabling notifications; when both are on, the banner stays silent so you hear one sound, not
  two. The chosen file is copied into `~/Library/Application Support/claudewatch/`, so it keeps
  working if you move or delete the original, and survives app updates.

## [1.2.1] - 2026-07-27

### Fixed
- A background sub-agent resumed after it finished (a follow-up message re-dispatches it) now
  shows as running again. Its completion had marked it done permanently, and the re-dispatched
  run's own completion notification — which carries only a task id, no tool-use id — was missed,
  so the agent could also have stayed running forever once un-marked.
- A resumed sub-agent no longer inherits its previous run's state: the stale `end_turn` that
  ended the earlier run no longer reads as "finished", and its last line no longer shows as the
  live activity of the new run.
- Clicking a card to focus its terminal/editor now works anywhere on the card, every time.
  Two causes: the 2s refresh rewrote the cards between mouse-down and mouse-up, which cancels the
  click; and since clicking a card hands focus to another app, claudewatch's next click was
  swallowed as a window-activation click.

## [1.2.0] - 2026-07-24

### Added
- **Menu-bar widget** — a status item showing a live session count and a state glyph that
  mirrors the panel cards: `●` working · `▸` input needed · `✓` all done · `⊘` interrupted,
  color-coded (green working/done, amber needs-you/interrupted). Its dropdown lists every live
  session (click a row to focus it), a "N need you" line, and Show / Quit. Toggle the whole
  widget off in Settings.
- **Custom menu-bar label** — templatable count text: `{n}` → count, `{s}` → auto-plural, and a
  `singular|plural` form for irregulars (`{n} worker{s}` → "3 workers"). Empty = `n session(s)`.
- **CPU / memory per session** — each card can show the session's CPU% and RSS, and the menu-bar
  title can sum them across all sessions (optionally stacked beside the label). Toggle in Settings.
- **Context usage per session** — each card can show the latest turn's context size in tokens
  (input + cache), formatted `117K`. Toggle in Settings.
- **Notifications** — optional system notification when a session finishes or needs input, with
  an optional sound. Permission is requested only when you enable notifications, not at launch.

### Changed
- Default menu-bar label is now `n session(s)` (was a bare number).
- Notification sound now defaults to off.
- A card stays "working" while it has a background sub-agent still running, even if the session's
  own status reads idle.

## [1.1.3] - 2026-07-23

### Changed
- Background sub-agents are now tracked exactly, not by count. Each agent is marked done by its
  own completion signal — whichever channel it arrives on: a background `<task-notification>`
  (by tool-use id) or a blocking `TaskOutput` poll (by task id), plus its own transcript
  concluding (`end_turn`) as a fallback. Fixes agents shown running after they finished, and
  agents shown/hidden as a FIFO group when several run at once.
- A running sub-agent's row shows its **live activity** — the latest line from its own
  transcript — instead of the static launch description, updating as it works.

## [1.1.2] - 2026-07-23

### Fixed
- Background sub-agents (scout, planner, general-purpose impl, …) launched via the newer async
  agent system now show as running. It polls completion via `TaskOutput` and leaves
  `pendingBackgroundAgentCount` at 0, which previously made claudewatch mark running agents done
  and hide them; running is now derived from launched-minus-terminated. `Task*` orchestration
  calls no longer overwrite the activity line.

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

[Unreleased]: https://github.com/renereose/claudewatch/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/renereose/claudewatch/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/renereose/claudewatch/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/renereose/claudewatch/compare/v1.1.3...v1.2.0
[1.1.3]: https://github.com/renereose/claudewatch/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/renereose/claudewatch/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/renereose/claudewatch/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/renereose/claudewatch/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/renereose/claudewatch/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/renereose/claudewatch/releases/tag/v1.0.0
