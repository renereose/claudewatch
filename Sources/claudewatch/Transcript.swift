// Transcript parsing — turns one session's ~/.claude/**/<id>.jsonl into a row dict.
// This is the format-specific layer: if Claude Code's log schema changes, it changes here.
import Foundation

// path -> (mtime, parsed row). ponytail: re-parse only when a file changes; unbounded but
// bounded in practice by session count. Add an LRU if you ever hoard thousands of sessions.
var cache: [String: (Double, [String: Any])] = [:]

func parse(_ path: String) -> [String: Any]? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    var title = "", prompt = "", cwd = "", activity = "", branch = "", state = "idle", wait = ""
    var model = "", pmode = ""                      // last model + permission mode seen
    var agentOrder: [String] = []                 // subagent tool_use ids, in call order
    var agentDesc: [String: String] = [:]
    var agentType: [String: String] = [:]
    var doneIds = Set<String>()                    // sync agents whose real result came back
    var asyncIds = Set<String>()                   // bg agents: launched, completion tracked by count
    var pending = 0                                // latest pendingBackgroundAgentCount
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
        case "system":      if let p = row["pendingBackgroundAgentCount"] as? Int { pending = p }
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
                } else { activity = "⚙ " + name }
            case "tool_result":
                if let id = c["tool_use_id"] as? String {
                    // bg agents return this placeholder at launch, not at completion
                    let body = String(describing: c["content"] ?? "")
                    if body.contains("Async agent launched successfully") { asyncIds.insert(id) }
                    else { doneIds.insert(id) }
                }
            default: break
            }
        }
    }
    // Async completions aren't logged per-agent — only the pending *count* is. Treat the last
    // `pending` bg agents (launch order) as still running; the rest as done.
    // ponytail: count is authoritative, which-specific-ones is FIFO-approximate. Upgrade if
    // Claude ever logs per-agent completion.
    let asyncOrder = agentOrder.filter { asyncIds.contains($0) }
    let runningAsync = Set(asyncOrder.suffix(min(pending, asyncOrder.count)))
    let agents = agentOrder.suffix(12).map { id -> [String: Any] in
        let done = asyncIds.contains(id) ? !runningAsync.contains(id) : doneIds.contains(id)
        return ["desc": agentDesc[id] ?? "agent", "type": agentType[id] ?? "agent",
                "done": done, "bg": asyncIds.contains(id)]
    }
    if state == "done" && pending > 0 { state = "working" }      // bg agents still running
    return ["title": title, "prompt": prompt, "cwd": cwd, "branch": branch,
            "activity": activity, "agents": agents, "state": state, "wait": wait,
            "model": model, "mode": pmode]
}
