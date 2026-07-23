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
func liveSessions(_ base: URL) -> [String: (tty: String, status: String, wait: String)] {
    let fm = FileManager.default
    let dir = base.appendingPathComponent("sessions")
    var live: [String: (tty: String, status: String, wait: String)] = [:]
    guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return live }
    for f in files where f.hasSuffix(".json") {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let pid = j["pid"] as? Int32, let sid = j["sessionId"] as? String else { continue }
        if kill(pid, 0) == 0 {                            // process still alive
            live[sid] = (ttyOf(pid), j["status"] as? String ?? "", j["waitingFor"] as? String ?? "")
        }
    }
    return live
}

// Bring the Terminal.app tab on `tty` to the front. (First use prompts for Automation access.)
func focusTerminal(_ tty: String) {
    guard !tty.isEmpty else { return }
    let script = """
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
    let p = Process(); p.launchPath = "/usr/bin/osascript"; p.arguments = ["-e", script]
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
            let allAgents = row["agents"] as? [[String: Any]] ?? []
            row["agents"] = allAgents.filter { !($0["done"] as? Bool ?? false) }   // live agents only
            let name = (row["cwd"] as? String).flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
                       ?? proj
            row["name"] = name
            row["tty"] = s.tty
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
