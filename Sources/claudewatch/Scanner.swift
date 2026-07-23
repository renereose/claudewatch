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
func ttyOf(_ pid: Int32) -> String {
    let p = Process(); p.launchPath = "/bin/ps"; p.arguments = ["-o", "tty=", "-p", "\(pid)"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    let s = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (s.isEmpty || s == "??") ? "" : "/dev/" + s
}

// Only sessions with a running claude process. <base>/sessions/<pid>.json holds
// {pid, sessionId, cwd, status, waitingFor}; stale files linger after a crash so we verify
// the pid. status ∈ idle|busy|shell|waiting; waitingFor names what a "waiting" session wants
// (e.g. "input needed", "dialog open", a permission label) — authoritative, so we skip the
// transcript for it. -> sid:(tty, status, wait)
func liveSessions(_ base: URL) -> [String: (tty: String, status: String, wait: String, pid: Int32)] {
    let fm = FileManager.default
    let dir = base.appendingPathComponent("sessions")
    var live: [String: (tty: String, status: String, wait: String, pid: Int32)] = [:]
    guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return live }
    for f in files where f.hasSuffix(".json") {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let pid = j["pid"] as? Int32, let sid = j["sessionId"] as? String else { continue }
        if kill(pid, 0) == 0 {                            // process still alive
            live[sid] = (ttyOf(pid), j["status"] as? String ?? "", j["waitingFor"] as? String ?? "", pid)
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
            let name = (row["cwd"] as? String).flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
                       ?? proj
            row["name"] = name
            row["tty"] = s.tty
            row["pid"] = Int(s.pid)                       // for IDE-hosted sessions (no tty): focus by pid+cwd
            row["host"] = hostBadge(tty: s.tty, pid: s.pid)   // card badge: cursor/code/warp/iterm/…
            row["ago"] = Int(now - mtime)
            // Live status overrides the transcript guess: it knows a dialog is open (waiting)
            // or work is running (busy/shell). idle/unknown -> keep transcript done/interrupted.
            switch s.status {
            case "waiting":       row["state"] = "waiting"; row["wait"] = s.wait
            case "busy", "shell": row["state"] = "working"
            default: break
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
