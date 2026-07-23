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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon; it's a HUD
let delegate = AppDelegate()
app.delegate = delegate
app.run()
