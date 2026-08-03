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

// --serve [host:]port: the same JSON as --dump, over HTTP, so something off this Mac can read it.
// Loopback unless a host is spelled out — the payload carries cwd paths, branches and your prompt.
if let i = CommandLine.arguments.firstIndex(of: "--serve"), i + 1 < CommandLine.arguments.count {
    guard let a = parseServeAddr(CommandLine.arguments[i + 1]) else {
        FileHandle.standardError.write(Data("usage: claudewatch --serve [host:]port\n".utf8)); exit(1)
    }
    try serve(host: a.host, port: a.port)
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

    // Custom "needs you" sound: unset or unreadable must be a silent no-op, a real file must play.
    d.soundFile = ""
    ok(!d.playWaitSound(), "no custom sound → silence")
    d.soundFile = "/nope/does-not-exist.mp3"
    ok(!d.playWaitSound(), "missing file → silence, no crash")
    d.soundFile = "/System/Library/Sounds/Ping.aiff"
    ok(d.playWaitSound(), "readable audio file → plays")
    d.waitSound?.stop()

    // The picked file is copied out of harm's way: deleting the original must not kill the sound.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cwtest-\(getpid())")
    let orig = tmp.appendingPathComponent("mine.aiff")
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try! FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff"), to: orig)
    let kept = d.keepCopy(orig, into: tmp)
    ok(kept.path != orig.path, "picked file is copied, not referenced in place")
    try! FileManager.default.removeItem(at: orig)                 // user deletes the original
    d.soundFile = kept.path
    ok(d.playWaitSound(), "still plays after the original is deleted")
    d.waitSound?.stop()
    ok(d.keepCopy(kept, into: tmp).path == kept.path, "re-picking our own copy is a no-op")
    try? FileManager.default.removeItem(at: tmp)

    // Update check compares release tags numerically, not as strings.
    ok(AppDelegate.isNewer("1.5.0", than: "1.4.0"), "1.5.0 > 1.4.0")
    ok(AppDelegate.isNewer("1.10.0", than: "1.9.0"), "1.10.0 > 1.9.0 (not a string compare)")
    ok(AppDelegate.isNewer("2.0", than: "1.9.9"), "missing fields count as 0")
    ok(!AppDelegate.isNewer("1.4.0", than: "1.4.0"), "same version → no update")
    ok(!AppDelegate.isNewer("1.3.9", than: "1.4.0"), "older release → no update")

    // Plugin staleness is read out of Claude Code's install ledger — newest entry wins, and a
    // plugin that isn't installed is never "behind".
    let ledger = """
    {"version":2,"plugins":{"other@x":[{"version":"9.9.9"}],
     "claudewatch@claudewatch":[{"scope":"local","version":"1.2.0"},{"scope":"user","version":"1.10.0"}]}}
    """.data(using: .utf8)!
    ok(AppDelegate.pluginVersion(from: ledger) == "1.10.0", "newest installed plugin scope wins")
    ok(AppDelegate.pluginVersion(from: Data("{\"plugins\":{}}".utf8)) == nil, "plugin not installed → nil")
    ok(AppDelegate.pluginVersion(from: Data("not json".utf8)) == nil, "unreadable ledger → nil, no crash")

    // Hotkey cycling: round-robin over the sessions that need you, wrapping, ignoring the rest.
    func w(_ pid: Int) -> [String: Any] { ["state": "waiting", "pid": pid] }
    let busy: [String: Any] = ["state": "working", "pid": 99]
    ok(AppDelegate.nextWaiting([], after: 0) == nil, "nothing at all → no jump target")
    ok(AppDelegate.nextWaiting([busy, ["state": "done", "pid": 98]], after: 0) == nil, "nothing waiting → no jump target")
    ok(AppDelegate.nextWaiting([w(1)], after: 0)?["pid"] as? Int == 1, "first press → first waiting session")
    ok(AppDelegate.nextWaiting([w(1)], after: 1)?["pid"] as? Int == 1, "one waiting session → keeps landing on it")
    ok(AppDelegate.nextWaiting([w(1), busy, w(2)], after: 1)?["pid"] as? Int == 2, "cycles past non-waiting rows")
    ok(AppDelegate.nextWaiting([w(1), w(2)], after: 2)?["pid"] as? Int == 1, "last waiting session wraps to the first")
    ok(AppDelegate.nextWaiting([w(1), w(2)], after: 77)?["pid"] as? Int == 1, "pid that finished → start over at the top")

    // Elapsed-time text, shared by the wait suffix and the re-nag body.
    ok(agoText(45) == "45s" && agoText(180) == "3m" && agoText(7200) == "2h", "agoText: 45s / 3m / 2h")

    // Re-nag: silent while off; once per nagEvery while on; the initial ping is stamped too, so
    // the first repeat lands a full interval later rather than on the next 2s refresh.
    let d2 = AppDelegate()
    d2.prevState = [7: "working"]                       // already seen, so the flip below is a transition
    let waitRows: [[String: Any]] = [["state": "waiting", "pid": 7, "name": "x", "wait": "plan review"]]
    d2.fireNotifications(waitRows, now: 1000)           // flips working → waiting: pings, stamps
    ok(d2.lastNag[7] == 1000, "entering waiting stamps the nag clock")
    d2.renagOn = false
    d2.fireNotifications(waitRows, now: 9999)
    ok(d2.lastNag[7] == 1000, "re-nag off → still waiting never re-pings")
    d2.renagOn = true
    d2.fireNotifications(waitRows, now: 1000 + d2.nagEvery - 1)
    ok(d2.lastNag[7] == 1000, "re-nag on but not due yet → no re-ping")
    d2.fireNotifications(waitRows, now: 1000 + d2.nagEvery)
    ok(d2.lastNag[7] == 1000 + d2.nagEvery, "re-nag on and due → re-pings and re-stamps")
    d2.fireNotifications([["state": "working", "pid": 7]], now: 2000)
    ok(d2.lastNag[7] == nil, "wait ended → nag clock cleared, next wait pings fresh")

    // --serve response framing. Body length must match the header or clients hang on a short read.
    let body = Data("[{\"a\":1}]".utf8)
    let resp = String(data: httpResponse(body), encoding: .utf8)!
    ok(resp.hasPrefix("HTTP/1.1 200 OK\r\n"), "serve: status line")
    ok(resp.contains("Content-Length: \(body.count)\r\n"), "serve: Content-Length matches the body")
    ok(resp.hasSuffix("\r\n\r\n[{\"a\":1}]"), "serve: blank line then the body verbatim")

    // Bind address is a trust boundary: a bare port must never reach past loopback.
    ok(parseServeAddr("8787")?.host == "127.0.0.1", "bare port → loopback only")
    ok(parseServeAddr("8787")?.port == 8787, "bare port → that port")
    ok(parseServeAddr("0.0.0.0:8787")?.host == "0.0.0.0", "LAN exposure has to be spelled out")
    ok(parseServeAddr("[::1]:8787")?.host == "::1", "bracketed IPv6 literal unwraps")
    ok(parseServeAddr("nope") == nil, "non-numeric port → rejected")
    ok(parseServeAddr(":8787") == nil, "empty host → rejected")

    print("selftest passed"); exit(0)
}

// --selftest-update <Claudewatch.app>: run the real updater — download the latest release and
// swap it in for the given app copy. Point it at a throwaway copy, never your installed one.
if let i = CommandLine.arguments.firstIndex(of: "--selftest-update"), i + 1 < CommandLine.arguments.count {
    let app = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    do { try AppDelegate.downloadAndReplace(app: app); print("replaced \(app.path)"); exit(0) }
    catch { FileHandle.standardError.write("update failed: \(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }
}

// --html: print the runtime UI document (for offline/browser UI testing).
if CommandLine.arguments.contains("--html") { print(HTML); exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon; it's a HUD
let delegate = AppDelegate()
app.delegate = delegate
app.run()
