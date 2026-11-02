// Session discovery — finds live Claude Code sessions on disk, reads their authoritative
// status, and assembles the rows the UI renders. Filesystem + process glue lives here.
import Foundation

let HOME = FileManager.default.homeDirectoryForCurrentUser

// Every ~/.claude* dir with sessions/ + projects/ — covers CLAUDE_CONFIG_DIR aliases
// like `claude-creem` (~/.claude-creem). New alias => auto-detected, no code change.
func configRoots() -> [URL] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: HOME.path) else { return [] }
    return entries.filter { $0.hasPrefix(".claude") }.map { HOME.appendingPathComponent($0) }
        .filter { fm.fileExists(atPath: $0.appendingPathComponent("sessions").path) &&
                  fm.fileExists(atPath: $0.appendingPathComponent("projects").path) }
}

// tty device the pid is attached to, e.g. "/dev/ttys003" — how we match a Terminal tab.
// libproc, not `ps`: this runs per session every 2s, and forking ps that often cost real battery.
func ttyOf(_ pid: Int32) -> String {
    var bi = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
          let name = devname(dev_t(bitPattern: bi.e_tdev), S_IFCHR) else { return "" }   // no tty → nil
    return "/dev/" + String(cString: name)
}

// A live session as its status file describes it. `name` is Claude Code's own session name
// (cwd-derived plus a disambiguator, so two sessions in one repo differ); `statusAt` is when
// `status` last changed, in epoch ms — for a waiting session, when the wait began. Both are
// absent on older Claude Code builds, hence the empty/zero defaults.
struct Live {
    let tty: String, status: String, wait: String, name: String
    let pid: Int32
    let statusAt: Double
}

// Only sessions with a running claude process. <base>/sessions/<pid>.json holds
// {pid, sessionId, cwd, status, waitingFor, name, statusUpdatedAt}; stale files linger after a
// crash so we verify the pid. status ∈ idle|busy|shell|waiting; waitingFor names what a "waiting"
// session wants (e.g. "input needed", "dialog open", a permission label) — authoritative, so we
// skip the transcript for it.
func liveSessions(_ base: URL) -> [String: Live] {
    let fm = FileManager.default
    let dir = base.appendingPathComponent("sessions")
    var live: [String: Live] = [:]
    guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return live }
    for f in files where f.hasSuffix(".json") {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let pid = j["pid"] as? Int32, let sid = j["sessionId"] as? String else { continue }
        if kill(pid, 0) == 0 {                            // process still alive
            live[sid] = Live(tty: ttyOf(pid), status: j["status"] as? String ?? "",
                             wait: j["waitingFor"] as? String ?? "", name: j["name"] as? String ?? "",
                             pid: pid, statusAt: (j["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? 0)
        }
    }
    return live
}

// Which GUI terminal owns `tty` — walk the process tree on that tty up to launchd.
// Warp/iTerm/Terminal appear as an ancestor executable path. Defaults to Terminal.
func terminalApp(forTTY tty: String) -> String {
    let dev = tty.replacingOccurrences(of: "/dev/", with: "")
    let ps = Process(); ps.launchPath = "/bin/ps"; ps.arguments = ["-o", "pid=", "-t", dev]
    let pipe = Pipe(); ps.standardOutput = pipe; ps.standardError = Pipe()
    try? ps.run(); ps.waitUntilExit()
    let pids = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    guard var pid = pids.first else { return "Terminal" }
    while pid > 1 {                                   // ponytail: linear walk, terminals are shallow
        let q = Process(); q.launchPath = "/bin/ps"; q.arguments = ["-o", "ppid=,command=", "-p", "\(pid)"]
        let out = Pipe(); q.standardOutput = out; q.standardError = Pipe()
        try? q.run(); q.waitUntilExit()
        let line = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = line.lowercased()
        if lower.contains("warp.app") { return "Warp" }
        if lower.contains("iterm.app") || lower.contains("iterm2") { return "iTerm2" }
        if lower.contains("terminal.app") { return "Terminal" }
        guard let ppid = Int32(line.split(whereSeparator: \.isWhitespace).first ?? ""), ppid > 1 else { break }
        pid = ppid
    }
    return "Terminal"
}

// Bring the terminal tab on `tty` to the front. (First use prompts for Automation access.)
// Terminal/iTerm select the exact tab by tty; Warp has no per-tab AppleScript, so it's just activated.
func focusTerminal(_ tty: String) {
    guard !tty.isEmpty else { return }
    let script: String
    switch terminalApp(forTTY: tty) {
    case "Warp":
        script = "tell application \"Warp\" to activate"   // ponytail: no per-tab API, app-level focus only
    case "iTerm2":
        script = """
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  select w
                  select t
                  select s
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
    default:
        script = """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected of t to true
                set frontmost of w to true
                return
              end if
            end repeat
          end repeat
        end tell
        """
    }
    let p = Process(); p.launchPath = "/usr/bin/osascript"; p.arguments = ["-e", script]
    try? p.run()
}

// CPU% over the interval since the last call for this pid (0 on first sight) and RSS in MB.
// libproc, not `ps`, for the same battery reason as ttyOf.
// ponytail: main claude pid only, not its child/subagent tree; lastCPU is unbounded like hostCache.
var lastCPU: [Int32: (cpu: Double, at: Double)] = [:]     // pid -> (cpu ns, wall ns) at last call
let timebase: Double = { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) }()
func usageOf(_ pid: Int32) -> (cpu: Double, mem: Int) {
    var ti = proc_taskinfo()
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { return (0, 0) }
    let cpu = Double(ti.pti_total_user + ti.pti_total_system) * timebase   // mach ticks → ns
    let now = Double(DispatchTime.now().uptimeNanoseconds)
    defer { lastCPU[pid] = (cpu, now) }
    let pct = lastCPU[pid].map { now > $0.at ? max(0, cpu - $0.cpu) / (now - $0.at) * 100 : 0 } ?? 0
    return (pct, Int(ti.pti_resident_size / 1_048_576))
}

// The pid's executable path — tells which IDE hosts an editor session (its binary lives under
// ~/.cursor/extensions/… or ~/.vscode/extensions/…).
func commandOf(_ pid: Int32) -> String {
    let p = Process(); p.launchPath = "/bin/ps"; p.arguments = ["-o", "command=", "-p", "\(pid)"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

// (badge, macOS app name) for an editor-hosted session, keyed off the claude binary's path
// (the plugin ships it under ~/.cursor|.vscode|.windsurf/extensions/…). app "" = focus unknown.
func ideInfo(_ pid: Int32) -> (badge: String, app: String) {
    let cmd = commandOf(pid)
    if cmd.contains(".cursor")          { return ("cursor", "Cursor") }
    if cmd.contains(".windsurf")        { return ("windsurf", "Windsurf") }
    if cmd.contains(".vscode-insiders") { return ("insiders", "Visual Studio Code - Insiders") }
    if cmd.contains(".vscode")          { return ("code", "Visual Studio Code") }
    return ("ide", "")
}

// Short badge for the GUI terminal on `tty` — terminal | iterm | warp (defaults to terminal).
func terminalName(_ tty: String) -> String {
    switch terminalApp(forTTY: tty) {
    case "Warp":   return "warp"
    case "iTerm2": return "iterm"
    default:       return "terminal"
    }
}

// The card's host badge (cursor/code/warp/iterm/…). A session's host never changes, and both
// lookups shell out to `ps`, so memoize by pid — one walk per session for its whole life.
// ponytail: unbounded like `cache`; prune to live pids if it ever grows to matter.
var hostCache: [Int32: String] = [:]
func hostBadge(tty: String, pid: Int32) -> String {
    if let h = hostCache[pid] { return h }
    let h = tty.isEmpty ? ideInfo(pid).badge : terminalName(tty)
    hostCache[pid] = h
    return h
}

// Focus a session's home: a terminal tab if it has a tty, else the editor window that hosts it.
// Editor sessions (the claude-vscode plugin) run under the extension host with no tty.
func focusSession(tty: String, cwd: String, pid: Int32) {
    if !tty.isEmpty { focusTerminal(tty); return }
    let app = ideInfo(pid).app
    guard !app.isEmpty, !cwd.isEmpty else { return }
    // Re-opening the workspace folder raises the window already on it (VSCode/Cursor dedupe by root).
    // ponytail: opens a new window if that folder isn't already open; `code -r <cwd>` is the upgrade path.
    let p = Process(); p.launchPath = "/usr/bin/open"; p.arguments = ["-a", app, cwd]
    try? p.run()
}

// The one call the UI makes: all live sessions across all config roots, newest first,
// with waiting sessions floated to the top.
func scan() -> [[String: Any]] {
    let fm = FileManager.default
    let now = Date().timeIntervalSince1970
    var out: [[String: Any]] = []
    for base in configRoots() {
      let live = liveSessions(base)
      let root = base.appendingPathComponent("projects").path
      guard let projects = try? fm.contentsOfDirectory(atPath: root) else { continue }
      for proj in projects {
        let dir = root + "/" + proj
        for (sid, s) in live {                             // filename is "<sessionId>.jsonl"
            let path = dir + "/" + sid + ".jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mdate = attrs[.modificationDate] as? Date else { continue }
            let mtime = mdate.timeIntervalSince1970
            if cache[path]?.0 != mtime { if let p = parse(path) { cache[path] = (mtime, p) } }
            guard var row = cache[path]?.1 else { continue }
            let allAgents = (row["agents"] as? [[String: Any]] ?? []).map { a -> [String: Any] in
                // For a running bg agent, read its own transcript: live activity + whether it concluded.
                guard a["bg"] as? Bool ?? false, !(a["done"] as? Bool ?? false),
                      let id = a["id"] as? String,
                      let info = subagentInfo(mainPath: path, toolUseId: id) else { return a }
                var a = a
                if let act = info.activity { a["desc"] = act }
                if info.done { a["done"] = true }              // its transcript ended, even if main missed it
                return a
            }
            row["agents"] = allAgents.filter { !($0["done"] as? Bool ?? false) }   // live agents only
            // Claude Code's own session name when it has one — it disambiguates two sessions in the
            // same repo, which a bare cwd basename can't.
            row["name"] = s.name.isEmpty
                ? ((row["cwd"] as? String).flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent } ?? proj)
                : s.name
            row["tty"] = s.tty
            row["pid"] = Int(s.pid)                       // for IDE-hosted sessions (no tty): focus by pid+cwd
            row["host"] = hostBadge(tty: s.tty, pid: s.pid)   // card badge: cursor/code/warp/iterm/…
            let u = usageOf(s.pid); row["cpu"] = u.cpu; row["mem"] = u.mem
            row["ago"] = Int(now - mtime)
            // The session's own status file is authoritative for working-vs-idle. The transcript tail
            // is too noisy to derive it from (trailing meta/attachment/tool_result records make a naive
            // last-record read look "working" long after the turn ended). The one thing status can't
            // see is a bg agent still running in the background — that keeps the card working on idle.
            let bgActive = (row["agents"] as? [[String: Any]] ?? []).contains { $0["bg"] as? Bool ?? false }
            switch s.status {
            // statusUpdatedAt is stamped when the status changes, so for a waiting session it *is*
            // when the wait began — "needs you · 4m" is what decides which card you click first.
            case "waiting":
                row["state"] = "waiting"; row["wait"] = s.wait
                if s.statusAt > 0 { row["waitFor"] = max(0, Int(now - s.statusAt / 1000)) }
            case "busy", "shell": row["state"] = "working"
            case "idle":          if !bgActive && (row["state"] as? String) != "interrupted" { row["state"] = "done" }
            default:              if bgActive { row["state"] = "working" }   // unknown status: trust bg activity
            }
            out.append(row)
        }
      }
    }
    // Sessions that need you (waiting) float to the top, then most-recent first.
    return out.sorted { a, b in
        let aw = (a["state"] as? String) == "waiting", bw = (b["state"] as? String) == "waiting"
        return aw == bw ? (a["ago"] as! Int) < (b["ago"] as! Int) : aw
    }
}

// ── Subscription session window (5h) usage ───────────────────────────────────────────────────
// Claude Code hands its status-line hooks a `rate_limits` object with the live 5h/7d subscription
// windows (Pro/Max only, after the first API response). We can't fetch that ourselves — OAuth
// usage is off-limits to third-party tools — so we run *as* a status line, cache what Claude Code
// gives us, and read it back here. Account-wide, so one file (freshest write wins), not per-session.
func usageCachePath() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? HOME.appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("claudewatch/usage.json")
}

// Pull the 5h/7d windows out of a status-line stdin payload. nil when it carries no windows yet
// (early in a session, or a non-subscription account) — the caller must then leave the cache alone
// rather than overwrite a good reading with nothing.
func usageFromStatusline(_ j: [String: Any]) -> [String: Any]? {
    guard let rl = j["rate_limits"] as? [String: Any] else { return nil }
    var out: [String: Any] = [:]
    if let f = rl["five_hour"] as? [String: Any] {
        out["fivePct"] = f["used_percentage"]; out["fiveReset"] = f["resets_at"]
    }
    if let s = rl["seven_day"] as? [String: Any] {
        out["sevenPct"] = s["used_percentage"]; out["sevenReset"] = s["resets_at"]
    }
    return out.isEmpty ? nil : out
}

// The --statusline entry point: read the hook JSON, cache the windows, print a compact status line
// so this is a valid drop-in `statusLine.command`. Prints even when there are no windows to cache.
func writeStatusline() {
    // Run by hand in a terminal (stdin is a TTY)? It'd block forever waiting on EOF — print how to
    // wire it up instead. Claude Code invokes it with a pipe, so this guard never fires there.
    if isatty(FileHandle.standardInput.fileDescriptor) != 0 {
        print("claudewatch --statusline reads Claude Code's status-line JSON on stdin — don't run it directly.")
        print("Put it in ~/.claude/settings.json instead:")
        print("  \"statusLine\": { \"type\": \"command\", \"command\": \"\(CommandLine.arguments.first ?? "claudewatch") --statusline\" }")
        return
    }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let j = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    let model = (j["model"] as? [String: Any])?["display_name"] as? String ?? "claude"
    var line = "[\(model)]"
    if let ctx = ((j["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.intValue {
        line += " \(ctx)% ctx"
    }
    if var u = usageFromStatusline(j) {
        u["at"] = Date().timeIntervalSince1970
        if let p = (u["fivePct"] as? NSNumber)?.intValue { line += " · 5h \(p)%" }
        if let d = try? JSONSerialization.data(withJSONObject: u) {
            let path = usageCachePath()
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: path)
        }
    }
    print(line)
}

// Last cached windows, for the HUD's usage bar. nil until a status line has fed us one.
func sessionUsage() -> [String: Any]? {
    guard let d = try? Data(contentsOf: usageCachePath()),
          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
    return j
}
