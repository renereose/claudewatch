// claudewatch — always-on-top HUD of your live Claude Code sessions.
// Run:  swift run claudewatch          (GUI, floating window)
//       swift run claudewatch --dump   (print the scanned JSON and exit — doubles as a test)
//       ./build.sh                      (package the distributable Claudewatch.app)
// ponytail: reads ~/.claude/projects/**/*.jsonl directly. No server, no deps.
//
// Entry point only — the app is split by responsibility:
//   Transcript.swift   parse one session's .jsonl into a row
//   Scanner.swift      discover live sessions + assemble rows (scan)
//   WebUI.swift        the HTML/CSS/JS document (HTML)
//   DragView.swift     native drag handle for the borderless panel
//   AppDelegate.swift  window, JS bridge, refresh loop
import Cocoa

// --dump: self-check / debug. Prints scanned sessions as JSON and exits. Doubles as a smoke test.
if CommandLine.arguments.contains("--dump") {
    let rows = scan()
    let data = try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
    print(String(data: data, encoding: .utf8)!)
    FileHandle.standardError.write("— \(rows.count) live session(s)\n".data(using: .utf8)!)
    exit(0)
}

// --selftest: assert the status mapping for every session state. No app/UI needed.
if CommandLine.arguments.contains("--selftest") {
    let d = AppDelegate()
    func ok(_ cond: Bool, _ msg: String) { print(cond ? "  ok  \(msg)" : "  FAIL \(msg)"); if !cond { exit(1) } }

    // Per-session marker glyphs (dropdown + shared with the panel cards).
    ok(d.mark("done") == "✓", "done → ✓")
    ok(d.mark("interrupted") == "⊘", "interrupted → ⊘")
    ok(d.mark("waiting") == "▸", "waiting (input needed) → ▸")
    ok(d.mark("working") == "●", "working → ●")
    ok(d.mark("idle") == "○", "idle → ○")

    // Menu-bar dot state: input-needed outranks working outranks idle.
    let waitRow: [String: Any] = ["state": "waiting"], workRow: [String: Any] = ["state": "working"]
    let doneRow: [String: Any] = ["state": "done"], idleRow: [String: Any] = ["state": "idle"]
    ok(AppDelegate.dotState([]) == "idle", "no sessions → idle dot")
    ok(AppDelegate.dotState([doneRow, idleRow]) == "idle", "only done/idle → idle dot")
    ok(AppDelegate.dotState([workRow, idleRow]) == "working", "any working → green dot")
    ok(AppDelegate.dotState([workRow, waitRow]) == "waiting", "any waiting outranks working → amber dot")

    // Menu-bar title: state glyph (same set as list rows) + count + summed cpu/ram.
    ok(d.statusTitle([]) == "◉ idle", "empty → ◉ idle")
    ok(d.statusTitle([["state": "working", "cpu": 12.4, "mem": 480]]) == "● 1 session · 12% · 480M", "working → ● glyph + totals")
    ok(d.statusTitle([["state": "done", "cpu": 10.0, "mem": 600], ["state": "done", "cpu": 20.0, "mem": 700]]) == "✓ 2 sessions · 30% · 1.3G", "all done → ✓ + GB rollover")
    ok(d.statusTitle([["state": "waiting", "cpu": 0, "mem": 0]]) == "▸ 1 session · 0% · 0M", "input needed → ▸ glyph")
    ok(d.lead([["state": "interrupted"]]).glyph == "⊘", "all interrupted → ⊘")

    print("selftest passed"); exit(0)
}

// --html: print the runtime UI document (for offline/browser UI testing).
if CommandLine.arguments.contains("--html") { print(HTML); exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon; it's a HUD
let delegate = AppDelegate()
app.delegate = delegate
app.run()
