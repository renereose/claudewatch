// Transcript parsing — turns one session's ~/.claude/**/<id>.jsonl into a row dict.
// This is the format-specific layer: if Claude Code's log schema changes, it changes here.
import Foundation

// path -> (mtime, parsed row). ponytail: re-parse only when a file changes; unbounded but
// bounded in practice by session count. Add an LRU if you ever hoard thousands of sessions.
var cache: [String: (Double, [String: Any])] = [:]

// First substring of `s` between `a` and `b`, or nil.
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let lo = s.range(of: a), let hi = s.range(of: b, range: lo.upperBound..<s.endIndex)
    else { return nil }
    return String(s[lo.upperBound..<hi.lowerBound])
}

// A running bg agent's own transcript, read fresh each scan. Returns its live activity (the last
// line it wrote — what Claude Code shows instead of the static launch description) and whether it
// has concluded (last assistant turn ended in end_turn) — a completion signal for fire-and-forget
// agents whose done never reaches the main transcript. Subagent files live beside the main one in
// <main-without-.jsonl>/subagents/; the .meta.json maps launch toolUseId -> file.
func subagentInfo(mainPath: String, toolUseId: String) -> (activity: String?, done: Bool)? {
    let dir = String(mainPath.dropLast(6)) + "/subagents"   // strip ".jsonl"
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    guard let meta = files.first(where: { $0.hasSuffix(".meta.json") &&
            ((try? String(contentsOfFile: dir + "/" + $0)) ?? "").contains("\"toolUseId\":\"\(toolUseId)\"") })
    else { return nil }
    let jsonl = dir + "/" + meta.dropLast(10) + ".jsonl"     // strip ".meta.json", add ".jsonl"
    guard let text = try? String(contentsOfFile: jsonl, encoding: .utf8) else { return nil }
    var activity: String? = nil, done = false, sawAssistant = false
    for line in text.split(separator: "\n").reversed() {
        guard let d = line.data(using: .utf8),
              let r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
        let msg = r["message"] as? [String: Any]
        if !sawAssistant, (r["type"] as? String) == "assistant" {
            sawAssistant = true
            done = (msg?["stop_reason"] as? String) == "end_turn"
        }
        if activity == nil, let content = msg?["content"] as? [[String: Any]] {
            for c in content.reversed() where (c["type"] as? String) == "text" {
                if let t = (c["text"] as? String)?.split(separator: "\n").first
                            .map({ $0.trimmingCharacters(in: .whitespaces) }), !t.isEmpty {
                    activity = String(t.prefix(120)); break
                }
            }
        }
        if activity != nil && sawAssistant { break }
    }
    return (activity, done)
}

func parse(_ path: String) -> [String: Any]? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    var title = "", prompt = "", cwd = "", activity = "", branch = "", state = "idle", wait = ""
    var model = "", pmode = ""                      // last model + permission mode seen
    var agentOrder: [String] = []                 // subagent tool_use ids, in call order
    var agentDesc: [String: String] = [:]
    var agentType: [String: String] = [:]
    var doneIds = Set<String>()                    // sync agents whose real result came back
    var asyncIds = Set<String>()                   // bg agents launched (keyed by their Agent tool_use id)
    var asyncDoneIds = Set<String>()               // bg agents that reported terminal, same id
    var taskTool: [String: String] = [:]           // bg agent's task_id -> its Agent tool_use id
    for line in text.split(separator: "\n") {
        guard let d = line.data(using: .utf8),
              let row = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
        if let c = row["cwd"] as? String { cwd = c }
        if let b = row["gitBranch"] as? String { branch = b }
        if let m = (row["message"] as? [String: Any])?["model"] as? String, !m.isEmpty { model = m }
        if let pm = row["permissionMode"] as? String, !pm.isEmpty { pmode = pm }
        switch row["type"] as? String {
        case "ai-title":    title = row["aiTitle"] as? String ?? title
        case "last-prompt": prompt = row["lastPrompt"] as? String ?? prompt
        // A bg agent's completion arrives as a <task-notification> attachment carrying the
        // launching Agent tool_use id and a terminal <status> — the authoritative "it's done".
        case "attachment":
            let p = (row["attachment"] as? [String: Any])?["prompt"] as? String ?? ""
            if p.contains("<task-notification>"), let id = between(p, "<tool-use-id>", "</tool-use-id>"),
               ["completed", "failed", "stopped", "cancelled"].contains(where: { p.contains("<status>\($0)</status>") }) {
                asyncDoneIds.insert(id)
            }
        default: break
        }
        // tool_use lives in assistant msgs, tool_result in user msgs — scan both.
        let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        // Session state from the *last* relevant record (last-wins) so ✓ clears when work resumes.
        switch row["type"] as? String {
        case "user":
            let interrupted = content.contains {
                ($0["type"] as? String) == "text" &&
                (($0["text"] as? String) ?? "").contains("[Request interrupted by user") }
            state = interrupted ? "interrupted" : "working"     // else: new prompt or tool_result
        case "assistant":
            let sr = (row["message"] as? [String: Any])?["stop_reason"] as? String ?? ""
            state = (sr == "end_turn") ? "done" : "working"     // end_turn => concluded
            // A tool that blocks on the user (question / plan approval) is "needs you", not "working".
            // Last-wins: a later user record (the answer) flips this back to working.
            let blocking = content.compactMap {
                ($0["type"] as? String) == "tool_use" ? $0["name"] as? String : nil
            }.first { $0 == "AskUserQuestion" || $0 == "ExitPlanMode" }
            if let b = blocking { state = "waiting"; wait = b == "ExitPlanMode" ? "plan review" : "input needed" }
        default: break                                          // system/attachment don't change it
        }
        for c in content {
            switch c["type"] as? String {
            case "text":
                if let t = c["text"] as? String, !t.isEmpty { activity = t }
            case "tool_use":
                let name = c["name"] as? String ?? "tool"
                if name == "Agent" || name == "Task", let id = c["id"] as? String {
                    let input = c["input"] as? [String: Any]
                    if agentDesc[id] == nil { agentOrder.append(id) }
                    agentDesc[id] = input?["description"] as? String ?? "agent"
                    agentType[id] = input?["subagent_type"] as? String ?? "agent"
                } else if !name.hasPrefix("Task") { activity = "⚙ " + name }   // Task* is plumbing, not activity
            case "tool_result":
                if let id = c["tool_use_id"] as? String {
                    let body = String(describing: c["content"] ?? "")
                    if body.contains("Async agent launched successfully") {
                        asyncIds.insert(id)                    // id = the Agent tool_use id
                        // Same record carries the bg agent's task_id; remember the pairing so a later
                        // TaskOutput poll (which only knows the task_id) can mark THIS agent done.
                        if let x = (row["toolUseResult"] as? [String: Any])?["agentId"] as? String { taskTool[x] = id }
                    } else {
                        doneIds.insert(id)
                        // A blocking TaskOutput poll returns the bg agent's task_id + terminal status.
                        if let x = between(body, "<task_id>", "</task_id>"), let t = taskTool[x],
                           ["completed", "failed", "stopped", "cancelled"].contains(where: { body.contains("<status>\($0)</status>") }) {
                            asyncDoneIds.insert(t)
                        }
                    }
                }
            default: break
            }
        }
    }
    // Each agent's done-ness is now exact: sync agents by their tool_result, bg agents by whether a
    // completion notification arrived for their id. No counting, no FIFO guessing.
    let agents = agentOrder.suffix(12).map { id -> [String: Any] in
        let done = asyncIds.contains(id) ? asyncDoneIds.contains(id) : doneIds.contains(id)
        return ["id": id, "desc": agentDesc[id] ?? "agent", "type": agentType[id] ?? "agent",
                "done": done, "bg": asyncIds.contains(id)]
    }
    let bgRunning = !asyncIds.subtracting(asyncDoneIds).isEmpty
    if state == "done" && bgRunning { state = "working" }        // bg agents still running
    return ["title": title, "prompt": prompt, "cwd": cwd, "branch": branch,
            "activity": activity, "agents": agents, "state": state, "wait": wait,
            "model": model, "mode": pmode]
}
