// The window + controller. Owns the borderless floating panel, hosts the WKWebView, bridges
// JS <-> Swift (focus/cfg/fit/drag/quit messages), manages drag handles, and refreshes every 2s.
import Cocoa
import WebKit
import UserNotifications
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var web: WKWebView!
    var panel: NSPanel!
    var status: NSStatusItem!                        // menu-bar indicator (there's no dock icon)
    var lastRows: [[String: Any]] = []               // latest scan, for the dropdown (rebuilt on open)
    var grips: [DragView] = []                       // drag handles (bubble: whole pill; list: bar gaps)

    // Pop to the front even when "float above all windows" is off (level == .normal).
    @objc func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func focusItem(_ sender: NSMenuItem) {      // click a session row → focus its terminal/editor
        guard let r = sender.representedObject as? [String: Any] else { return }
        focusSession(tty: r["tty"] as? String ?? "", cwd: r["cwd"] as? String ?? "",
                     pid: (r["pid"] as? NSNumber)?.int32Value ?? 0)
    }

    // Same status glyphs as the panel cards: ✓ done, ⊘ interrupted, ▸ waiting, ● working, ○ idle.
    func mark(_ state: String) -> String {
        switch state {
        case "done": return "✓"; case "interrupted": return "⊘"
        case "waiting": return "▸"; case "working": return "●"; default: return "○"
        }
    }

    // The count label for the menu-bar title. Empty format => just the number. Otherwise the user's
    // template, with {n} -> count and {s} -> ""/"s" (auto-plural). A "singular|plural" template picks
    // the side by count, for irregulars: "{n} worker{s}" -> "3 workers"; "1 child|{n} children" -> "1 child".
    func statusLabel(_ n: Int) -> String {
        let f = statusFmt.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return "\(n) session\(n == 1 ? "" : "s")" }
        let side = f.contains("|") ? (f.components(separatedBy: "|")[n == 1 ? 0 : 1]) : f
        return side.replacingOccurrences(of: "{n}", with: "\(n)")
                   .replacingOccurrences(of: "{s}", with: n == 1 ? "" : "s")
    }
    // Menu-bar title: session count (or its custom label), plus total CPU%/RAM when "show cpu /
    // memory usage" is on (same toggle as the cards). Either way it doubles as a "running" light.
    func statusTitle(_ rows: [[String: Any]]) -> String {
        guard !rows.isEmpty else { return "◉ idle" }
        let g = lead(rows).glyph
        let label = statusLabel(rows.count)
        guard showUsage else { return "\(g) \(label)" }
        let cpu = rows.reduce(0.0) { $0 + (($1["cpu"] as? Double) ?? 0) }
        let mem = rows.reduce(0) { $0 + (($1["mem"] as? Int) ?? 0) }
        let m = mem >= 1024 ? String(format: "%.1fG", Double(mem) / 1024) : "\(mem)M"
        return "\(g) \(label) · \(Int(cpu.rounded()))% · \(m)"
    }

    // Overall menu-bar dot state: input-needed wins over working wins over idle.
    static func dotState(_ rows: [[String: Any]]) -> String {
        if rows.contains(where: { ($0["state"] as? String) == "waiting" }) { return "waiting" }
        if rows.contains(where: { ($0["state"] as? String) == "working" }) { return "working" }
        return "idle"
    }

    // Menu-bar lead marker: the same per-state glyph as the dropdown rows and the list view
    // (mark()), for the winning state — input-needed ▸ · working ● · all done ✓ · interrupted ⊘.
    func lead(_ rows: [[String: Any]]) -> (glyph: String, color: NSColor) {
        let amber = NSColor(red: 0.94, green: 0.72, blue: 0.40, alpha: 1)
        let green = NSColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1)
        if rows.isEmpty { return ("◉", .labelColor) }
        switch AppDelegate.dotState(rows) {
        case "waiting": return (mark("waiting"), amber)
        case "working": return (mark("working"), green)
        default:        // all finished: ✓ if any concluded cleanly, else ⊘ interrupted
            return rows.contains { ($0["state"] as? String) == "done" }
                 ? (mark("done"), green) : (mark("interrupted"), amber)
        }
    }

    // Color just the leading dot by state — same cue as the panel: amber = a session needs you,
    // green = work running, default = idle. ponytail: labelColor tracks the menu-bar appearance.
    func setStatus(_ rows: [[String: Any]]) {
        guard let btn = status?.button else { return }
        let dot = lead(rows).color
        // "stack stats" on: the count label sits large on the left, CPU/RAM stacked small to its
        // right (a custom-drawn view — a single title can't center a big run beside two small lines).
        // Only when there are sessions and usage is shown; otherwise fall back to a plain title.
        if statusStack, showUsage, !rows.isEmpty {
            let cpu = rows.reduce(0.0) { $0 + (($1["cpu"] as? Double) ?? 0) }
            let mem = rows.reduce(0) { $0 + (($1["mem"] as? Int) ?? 0) }
            let m = mem >= 1024 ? String(format: "%.1fG", Double(mem) / 1024) : "\(mem)M"
            let v = statView ?? { let v = StatusView(); statView = v; btn.addSubview(v); return v }()
            v.dot = dot; v.left = "\(lead(rows).glyph) \(statusLabel(rows.count))"
            v.top = "CPU \(Int(cpu.rounded()))%"; v.bottom = "RAM \(m)"
            v.invalidateIntrinsicContentSize()
            let w = v.intrinsicContentSize.width
            status.length = w
            v.frame = NSRect(x: 0, y: 0, width: w, height: NSStatusBar.system.thickness)
            v.needsDisplay = true
            btn.title = ""                               // the view draws everything; hide the button's own title
            return
        }
        statView?.removeFromSuperview(); statView = nil  // back to the single-line title path
        status.length = NSStatusItem.variableLength
        let s = NSMutableAttributedString(string: statusTitle(rows),
                                          attributes: [.foregroundColor: NSColor.labelColor])
        s.addAttribute(.foregroundColor, value: dot, range: NSRange(location: 0, length: 1))
        btn.attributedTitle = s
    }

    // Rebuilt each time the menu opens: header + one clickable row per session, then Show/Quit.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let n = lastRows.count
        menu.addItem(withTitle: n == 0 ? "no active sessions" : "\(n) session\(n == 1 ? "" : "s")",
                     action: nil, keyEquivalent: "")               // disabled header
        if n > 0 {
            let waiting = lastRows.filter { ($0["state"] as? String) == "waiting" }.count
            if waiting > 0 { menu.addItem(withTitle: "▸ \(waiting) need\(waiting == 1 ? "s" : "") you", action: nil, keyEquivalent: "") }
            menu.addItem(.separator())
        }
        for r in lastRows {
            let name = r["name"] as? String ?? "?"
            let state = r["state"] as? String ?? ""
            let cpu = Int((((r["cpu"] as? Double) ?? 0)).rounded()), mem = (r["mem"] as? Int) ?? 0
            let tail = state == "waiting" ? "needs you" : "\(cpu)% · \(mem)M"
            let it = NSMenuItem(title: "\(mark(state)) \(name)   \(tail)",
                                action: #selector(focusItem(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = r
            menu.addItem(it)
        }
        menu.addItem(.separator())
        for (title, sel, key) in [("Show claudewatch", #selector(showPanel), ""), ("Quit", #selector(quitApp), "q")] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self; menu.addItem(it)
        }
    }

    func makeGrip(_ f: NSRect, mask: NSView.AutoresizingMask, expandable: Bool) -> DragView {
        let g = DragView(frame: f)
        g.autoresizingMask = mask
        g.onMoved = { [weak self] in                 // remember where the user parked it
            guard let f = self?.panel.frame else { return }
            UserDefaults.standard.set(Double(f.maxX), forKey: "cw.right")
            UserDefaults.standard.set(Double(f.maxY), forKey: "cw.top")
        }
        if expandable { g.onClick = { [weak self] in  // click bubble → expand to list
            guard let self = self, self.mode == "bubble" else { return }
            self.mode = "list"; UserDefaults.standard.set("list", forKey: "cw.mode")
            self.listFallbackGrip(); self.applyWindow()
            self.web.evaluateJavaScript("setCfg('list',\(self.prefJSON))")
        } }
        return g
    }
    func setGrips(_ views: [DragView]) {
        grips.forEach { $0.removeFromSuperview() }
        grips = views
        views.forEach { panel.contentView!.addSubview($0) }
    }
    func bubbleGrip() {
        lastDrag = ""
        setGrips([makeGrip(panel.contentView!.bounds, mask: [.width, .height], expandable: true)])
    }
    func listFallbackGrip() {                         // small ⠿ handle until JS reports the bar gaps
        lastDrag = ""
        let cv = panel.contentView!
        setGrips([makeGrip(NSRect(x: 0, y: cv.bounds.height - 26, width: 26, height: 26),
                           mask: [.minYMargin, .maxXMargin], expandable: false)])
    }
    // Persisted view prefs. mode: list=full list, bubble=minimized pill. prefJSON is the JS
    // settings blob (opacity, toggles) — JS owns it; Swift persists it and applies the native bits.
    var mode = UserDefaults.standard.string(forKey: "cw.mode") == "bubble" ? "bubble" : "list"
    var prefJSON = UserDefaults.standard.string(forKey: "cw.pref") ?? "{}"
    var opacity = 1.0
    var showUsage = true                            // gates cpu/mem in the menu-bar title
    var notifyOn = false                            // fire a system notification on state changes (off by default)
    var soundOn = false                             // play a sound with notifications
    var soundFile = ""                              // custom audio played when a session needs you
    var waitSound: NSSound?                         // held: an NSSound that goes out of scope stops playing
    var statusFmt = ""                              // custom menu-bar count label (empty = plain number)
    var statusStack = true                          // big count label + CPU/RAM stacked to its right
    var statView: StatusView?                       // custom-drawn menu-bar content for stacked layout
    var prevState: [Int: String] = [:]              // pid -> last seen state, to detect transitions

    func applyPref(_ p: [String: Any]) {            // native side-effects of settings
        if let op = (p["op"] as? NSNumber)?.doubleValue { opacity = max(0.2, min(1, op)) }
        panel?.level = ((p["onTop"] as? NSNumber)?.boolValue ?? true) ? .floating : .normal
        showUsage = (p["showUsage"] as? NSNumber)?.boolValue ?? true
        notifyOn = (p["notify"] as? NSNumber)?.boolValue ?? false
        if notifyOn { requestNotifyAuth() }         // ask only once the user actually enables notifications
        soundOn = (p["sound"] as? NSNumber)?.boolValue ?? false
        soundFile = (p["soundFile"] as? String) ?? ""
        statusFmt = (p["slabel"] as? String) ?? ""
        statusStack = (p["statStack"] as? NSNumber)?.boolValue ?? true
        setMenuBar((p["menuBar"] as? NSNumber)?.boolValue ?? true)
        setStatus(lastRows)                         // repaint the title immediately on toggle
    }
    // Create/remove the menu-bar item on demand. Off = no status item; the floating panel still
    // shows everything and closing it (red button) still quits, so access isn't lost.
    func setMenuBar(_ show: Bool) {
        if show, status == nil {
            status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status.button?.title = "◉ …"
            let menu = NSMenu(); menu.delegate = self   // rebuilt on open via menuNeedsUpdate
            status.menu = menu
            setStatus(lastRows)
        } else if !show, let s = status {
            statView?.removeFromSuperview(); statView = nil   // its button is going away
            NSStatusBar.system.removeStatusItem(s); status = nil
        }
    }
    var contentH: CGFloat = 0                       // last measured page height (0 = not yet)
    var lastDrag = ""                               // last applied drag-gap layout (skip rebuilds)
    // Width from mode, height from the rendered page (clamped) — no dead space. Keep top-right pinned.
    func applyWindow() {
        let right = panel.frame.maxX, top = panel.frame.maxY   // top-right anchor, pre-resize
        let h = contentH > 0 ? contentH : 120
        panel.setContentSize(NSSize(width: mode == "bubble" ? 210 : 320, height: h))
        panel.setFrameTopLeftPoint(NSPoint(x: right - panel.frame.width, y: top))
        panel.alphaValue = CGFloat(opacity)
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "focus", let b = m.body as? [String: Any] {
            focusSession(tty: b["tty"] as? String ?? "", cwd: b["cwd"] as? String ?? "",
                         pid: (b["pid"] as? NSNumber)?.int32Value ?? 0)
        }
        if m.name == "cfg", let s = m.body as? String, let d = s.data(using: .utf8),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            if j["quit"] != nil { NSApp.terminate(nil); return }
            if j["pickSound"] != nil { pickSound(); return }
            if let f = (j["fit"] as? NSNumber)?.doubleValue { contentH = CGFloat(max(44, min(680, f))) }
            // Draggable bar gaps (list mode), in CSS px top-left → flip to view coords.
            if let dr = j["drag"] as? [[String: Any]], mode == "list" {
                let key = "\(panel.contentView!.bounds.height)|\(s)"   // gaps + height unchanged → skip
                if key == lastDrag { return }
                lastDrag = key
                let cvH = panel.contentView!.bounds.height
                setGrips(dr.map { r in
                    let x = (r["x"] as? NSNumber)?.doubleValue ?? 0, y = (r["y"] as? NSNumber)?.doubleValue ?? 0
                    let w = (r["w"] as? NSNumber)?.doubleValue ?? 0, h = (r["h"] as? NSNumber)?.doubleValue ?? 0
                    return makeGrip(NSRect(x: x, y: cvH - (y + h), width: w, height: h),
                                    mask: [.minYMargin], expandable: false)
                })
                return
            }
            if let mo = j["mode"] as? String, mo != mode {
                mode = mo; UserDefaults.standard.set(mo, forKey: "cw.mode")
                if mo == "bubble" { bubbleGrip() } else { listFallbackGrip() }
            }
            if let pref = j["pref"] as? [String: Any] {
                applyPref(pref)
                if let pd = try? JSONSerialization.data(withJSONObject: pref),
                   let ps = String(data: pd, encoding: .utf8) {
                    prefJSON = ps; UserDefaults.standard.set(ps, forKey: "cw.pref")
                }
            }
            applyWindow()
        }
    }
    func applicationDidFinishLaunching(_ n: Notification) {
        // Borderless: no macOS titlebar/traffic-lights to overlap the UI. Drag by background.
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "focus")
        cfg.userContentController.add(self, name: "cfg")
        let cv = panel.contentView!
        cv.wantsLayer = true
        cv.layer?.cornerRadius = 12                 // rounded widget corners
        cv.layer?.masksToBounds = true
        web = FirstMouseWebView(frame: cv.bounds, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString(HTML, baseURL: nil)
        cv.addSubview(web)
        if mode == "bubble" { bubbleGrip() } else { listFallbackGrip() }   // JS refines list gaps
        // Restore the saved top-right corner (clamped on-screen), else park top-right.
        let vf = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
        let d = UserDefaults.standard
        let ax = min(vf.maxX, max(vf.minX + 60, CGFloat(d.object(forKey: "cw.right") as? Double ?? Double(vf.maxX - 16))))
        let ay = min(vf.maxY, max(vf.minY + 60, CGFloat(d.object(forKey: "cw.top") as? Double ?? Double(vf.maxY - 16))))
        panel.setFrameTopLeftPoint(NSPoint(x: ax - panel.frame.width, y: ay))
        // Apply saved opacity + onTop, and create the menu-bar item unless the user disabled it.
        if let pd = prefJSON.data(using: .utf8),
           let p = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any] { applyPref(p) }
        else { setMenuBar(true) }            // no saved prefs yet → default the menu-bar item on
        applyWindow()                        // apply persisted mode + opacity, pin to that corner
        panel.makeKeyAndOrderFront(nil)
        if Bundle.main.bundleIdentifier != nil {         // notifications need a bundle id (the .app)
            UNUserNotificationCenter.current().delegate = self
        }                                                // auth is requested lazily when notifications are enabled
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.web.evaluateJavaScript("setCfg('\(self.mode)',\(self.prefJSON))")   // push prefs into the view
            self.refresh()
        }
    }
    // Ping when a session flips into "needs you" or finishes a turn. Keyed by pid; a session's
    // first appearance seeds prevState without firing, so startup (and new sessions) don't spam.
    func fireNotifications(_ rows: [[String: Any]]) {
        var next: [Int: String] = [:]
        for r in rows {
            guard let pid = r["pid"] as? Int, let st = r["state"] as? String else { continue }
            next[pid] = st
            guard let prev = prevState[pid], prev != st else { continue }
            let name = r["name"] as? String ?? "session"
            if st == "waiting" {
                // The custom sound stands on its own — no need to also enable notifications for it.
                let custom = playWaitSound()        // custom file replaces the banner's own sound
                if notifyOn {
                    notify(title: name, text: (r["wait"] as? String).map { "needs you — \($0)" } ?? "needs you",
                           pid: pid, silent: custom)
                }
            } else if notifyOn && st == "done" && prev == "working" {
                notify(title: name, text: "finished", pid: pid)
            }
        }
        prevState = next
    }
    // Bundled (.app) → post via UNUserNotificationCenter so the notification is owned by us:
    // clicking it activates claudewatch (and focuses the session), not Script Editor. The raw
    // dev binary has no bundle id — UN would crash — so it falls back to osascript there.
    // Ask for notification permission on demand. Idempotent — after the first decision macOS no-ops.
    func requestNotifyAuth() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // .app only; osascript path needs no auth
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Play the user's own audio file (mp3/wav/aiff/…). Returns true if it started, so the
    // notification can stay silent instead of stacking a second chime on top.
    @discardableResult func playWaitSound() -> Bool {
        guard !soundFile.isEmpty, let s = NSSound(contentsOfFile: soundFile, byReference: true) else { return false }
        waitSound?.stop(); waitSound = s        // ponytail: one at a time; last ping wins
        return s.play()
    }
    // Own a copy in ~/Library/Application Support/claudewatch/ so the sound survives the user
    // deleting/moving the original (Desktop, Downloads) and app updates — the .app bundle is
    // replaced wholesale on update, this folder isn't. Falls back to the original path on failure.
    func keepCopy(_ src: URL, into root: URL? = nil) -> URL {   // root: tests only
        let fm = FileManager.default
        guard let base = root ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return src }
        let dir = base.appendingPathComponent("claudewatch")
        let dst = dir.appendingPathComponent("needsyou." + (src.pathExtension.isEmpty ? "mp3" : src.pathExtension))
        if src.standardizedFileURL == dst.standardizedFileURL { return dst }   // re-picking our own copy
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Wipe old copies first: a previous pick may have had a different extension.
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where f.lastPathComponent.hasPrefix("needsyou.") { try? fm.removeItem(at: f) }
            try fm.copyItem(at: src, to: dst)
            return dst
        } catch { return src }
    }
    // Pick the file natively — the WebView can't hand us a usable path. NSApp.activate first:
    // the panel is non-activating, so without it the open panel opens behind everything.
    func pickSound() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.prompt = "Use sound"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        var pref = (try? JSONSerialization.jsonObject(with: Data(prefJSON.utf8))) as? [String: Any] ?? [:]
        pref["soundFile"] = keepCopy(url).path
        applyPref(pref)
        playWaitSound()                          // instant preview of what you just picked
        if let d = try? JSONSerialization.data(withJSONObject: pref), let s = String(data: d, encoding: .utf8) {
            prefJSON = s; UserDefaults.standard.set(s, forKey: "cw.pref")
            web.evaluateJavaScript("setCfg('\(mode)',\(s))")
        }
    }

    func notify(title: String, text: String, pid: Int = 0, silent: Bool = false) {
        if Bundle.main.bundleIdentifier != nil {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = text; c.sound = (soundOn && !silent) ? .default : nil
            c.userInfo = ["pid": pid]
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
            UNUserNotificationCenter.current().add(req)
            return
        }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
        let script = "display notification \"\(esc(text))\" with title \"\(esc(title))\"" + ((soundOn && !silent) ? " sound name \"Ping\"" : "")
        let p = Process(); p.launchPath = "/usr/bin/osascript"; p.arguments = ["-e", script]
        try? p.run()
    }
    // Clicking a notification: raise claudewatch and focus that session's terminal/editor.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive resp: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let pid = (resp.notification.request.content.userInfo["pid"] as? NSNumber)?.intValue ?? 0
        DispatchQueue.main.async {
            if let r = self.lastRows.first(where: { ($0["pid"] as? Int) == pid }) {
                focusSession(tty: r["tty"] as? String ?? "", cwd: r["cwd"] as? String ?? "",
                             pid: (r["pid"] as? NSNumber)?.int32Value ?? 0)
            } else { self.showPanel() }   // session gone (exited) → just surface the HUD
        }
        done()
    }
    // Still show the banner when claudewatch itself is frontmost.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done(soundOn ? [.banner, .sound] : [.banner])
    }
    func refresh() {
        let rows = scan()
        lastRows = rows
        fireNotifications(rows)
        setStatus(rows)
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("render(\(json))")
    }
    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }   // red button quits
}

// A borderless panel can't become key by default, so its text fields (the "menu-bar label"
// input) never receive keystrokes. nonactivatingPanel lets it take focus without activating the
// whole app, so typing works but your terminal stays in front.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Clicking a card focuses another app, so the panel is usually NOT key when you click it again —
// and an unkey window's first click is swallowed as an activation click unless the view opts in.
final class FirstMouseWebView: WKWebView {
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

// Menu-bar content for the stacked layout: a large count label on the left (its leading dot
// colored by state), CPU/RAM stacked in small text to its right. Lives as a subview of the status
// button, which still owns the click → menu. ponytail: pure draw, no events of its own.
final class StatusView: NSView {
    var dot = NSColor.labelColor
    var left = "", top = "", bottom = ""
    private let big = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let small = NSFont.systemFont(ofSize: 9)
    private func attr(_ s: String, _ f: NSFont) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor.labelColor])
    }
    private var leftAttr: NSMutableAttributedString {
        let a = NSMutableAttributedString(attributedString: attr(left, big))
        if !left.isEmpty { a.addAttribute(.foregroundColor, value: dot, range: NSRange(location: 0, length: 1)) }
        return a
    }
    override var intrinsicContentSize: NSSize {
        let l = leftAttr.size().width
        let r = max(attr(top, small).size().width, attr(bottom, small).size().width)
        return NSSize(width: ceil(l + 8 + r) + 10, height: NSStatusBar.system.thickness)
    }
    override func draw(_ dirty: NSRect) {
        let h = bounds.height
        let la = leftAttr, ls = la.size()
        la.draw(at: NSPoint(x: 5, y: (h - ls.height) / 2))     // big label, vertically centered
        let rx = 5 + ls.width + 8, ta = attr(top, small), ba = attr(bottom, small)
        ta.draw(at: NSPoint(x: rx, y: h / 2 + 0.5))            // origin is bottom-left: top line above center
        ba.draw(at: NSPoint(x: rx, y: h / 2 - ba.size().height - 0.5))
    }
}
