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
    var grips: [DragView] = []                       // drag handles: the header-strip gaps, both modes

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
        if !newVersion.isEmpty {
            let what = appStale ? "update available" : "plugin update"
            let it = NSMenuItem(title: "⬆ \(what) — v\(newVersion)", action: #selector(promptUpdate), keyEquivalent: "")
            it.target = self; menu.addItem(it)
        }
        for (title, sel, key) in [("Show claudewatch", #selector(showPanel), ""), ("Quit", #selector(quitApp), "q")] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self; menu.addItem(it)
        }
    }

    func makeGrip(_ f: NSRect, mask: NSView.AutoresizingMask) -> DragView {
        let g = DragView(frame: f)
        g.autoresizingMask = mask
        g.onMoved = { [weak self] in                 // remember where the user parked it
            guard let f = self?.panel.frame else { return }
            UserDefaults.standard.set(Double(f.maxX), forKey: "cw.right")
            UserDefaults.standard.set(Double(f.maxY), forKey: "cw.top")
        }
        return g
    }
    func setGrips(_ views: [DragView]) {
        grips.forEach { $0.removeFromSuperview() }
        grips = views
        views.forEach { panel.contentView!.addSubview($0) }
    }
    // Both modes: a small ⠿ handle in the top-left until JS reports its header's real gaps.
    // The bubble is NOT one big handle any more — only its header strip drags, so clicking a
    // session row reaches the web view and focuses that session.
    func listFallbackGrip() {
        lastDrag = ""
        let cv = panel.contentView!
        setGrips([makeGrip(NSRect(x: 0, y: cv.bounds.height - 26, width: 26, height: 26),
                           mask: [.minYMargin, .maxXMargin])])
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
    var updateOn = true                             // check GitHub for a newer release
    var newVersion = ""                             // set once a newer release is found
    let startVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    var appStale = false                            // this app build is behind that release
    var pluginStale = false                         // the installed Claude Code plugin is too
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
        updateOn = (p["upd"] as? NSNumber)?.boolValue ?? true
        if updateOn { checkUpdate() }               // re-enabled mid-session → check right away
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
            if j["update"] != nil { promptUpdate(); return }
            if let f = (j["fit"] as? NSNumber)?.doubleValue { contentH = CGFloat(max(44, min(680, f))) }
            // Draggable bar gaps (list mode), in CSS px top-left → flip to view coords.
            if let dr = j["drag"] as? [[String: Any]] {
                let key = "\(panel.contentView!.bounds.height)|\(s)"   // gaps + height unchanged → skip
                if key == lastDrag { return }
                lastDrag = key
                let cvH = panel.contentView!.bounds.height
                setGrips(dr.map { r in
                    let x = (r["x"] as? NSNumber)?.doubleValue ?? 0, y = (r["y"] as? NSNumber)?.doubleValue ?? 0
                    let w = (r["w"] as? NSNumber)?.doubleValue ?? 0, h = (r["h"] as? NSNumber)?.doubleValue ?? 0
                    return makeGrip(NSRect(x: x, y: cvH - (y + h), width: w, height: h),
                                    mask: [.minYMargin])
                })
                return
            }
            if let mo = j["mode"] as? String, mo != mode {
                mode = mo
                // temp: the pop-open (and its snap-back) when a session needs you. Applied, but
                // never written — otherwise one "needs you" would silently make list your
                // remembered mode and the bubble would never come back.
                if (j["temp"] as? NSNumber)?.boolValue != true { UserDefaults.standard.set(mo, forKey: "cw.mode") }
                listFallbackGrip()
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
        listFallbackGrip()   // JS refines it to the header gaps once rendered
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
        checkUpdate()                        // and hourly, for HUDs that stay up for days
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in self.checkUpdate() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self.restartIfReplaced() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.web.evaluateJavaScript("setCfg('\(self.mode)',\(self.prefJSON))")   // push prefs into the view
            self.refresh()
        }
    }
    // Update check: one unauthenticated GET to the GitHub releases API, at launch and hourly.
    // Nothing is sent but the request itself, nothing is downloaded or installed — a newer tag
    // just lights up a notice in the HUD and the menu, which opens the releases page when clicked.
    // Dev builds have no bundle version, so they never check. Off via Settings → check for updates.
    func checkUpdate() {
        guard updateOn, newVersion.isEmpty,
              let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let u = URL(string: "https://api.github.com/repos/renereose/claudewatch/releases/latest")
        else { return }
        URLSession.shared.dataTask(with: u) { [weak self] d, _, _ in
            guard let d, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let tag = j["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            // The app and the Claude Code plugin ship from the same tag but update through
            // different channels, so either can be the stale one.
            let appOld = AppDelegate.isNewer(latest, than: cur)
            let plugOld = AppDelegate.installedPluginVersion().map { AppDelegate.isNewer(latest, than: $0) } ?? false
            guard appOld || plugOld else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.newVersion = latest; self.appStale = appOld; self.pluginStale = plugOld
                self.web.evaluateJavaScript("setUpdate('\(latest)',\(appOld ? 1 : 0),\(plugOld ? 1 : 0))")
            }
        }.resume()
    }
    // Version of the installed Claude Code plugin, from Claude Code's own install ledger.
    // Read-only: Claude Code owns updating its plugins, we only notice when ours is behind.
    static func installedPluginVersion() -> String? {
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let d = try? Data(contentsOf: p) else { return nil }
        return pluginVersion(from: d)
    }
    // Newest version across the ledger's entries — the same plugin can be installed at more than
    // one scope. nil when it isn't installed at all (then there's nothing to be behind).
    static func pluginVersion(from data: Data) -> String? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let all = j["plugins"] as? [String: Any],
              let mine = all["claudewatch@claudewatch"] as? [[String: Any]] else { return nil }
        return mine.compactMap { $0["version"] as? String }.max { isNewer($1, than: $0) }
    }
    // Numeric field-by-field compare — "1.10.0" is newer than "1.9.0". Missing fields count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    // Restart into whatever build is on disk now. Used after our own update, and by the minute
    // check below when someone else replaced the bundle underneath us.
    func relaunchSelf() {
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    // The bundle we launched from can be swapped while we run — a manual download dropped into
    // /Applications, a sync, another window's updater. The running process keeps the old code
    // until something restarts it, so read the version off disk each minute and restart on change.
    // The fresh instance starts equal to disk, so this can't loop.
    func restartIfReplaced() {
        guard Bundle.main.bundleIdentifier != nil, !startVersion.isEmpty else { return }
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist),
              let onDisk = d["CFBundleShortVersionString"] as? String,
              onDisk != startVersion else { return }
        relaunchSelf()
    }
    @objc func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/renereose/claudewatch/releases/latest")!)
    }
    static let zipURL = URL(string: "https://github.com/renereose/claudewatch/releases/latest/download/Claudewatch.zip")!

    // Download the release zip and swap it in for `app`. Blocking — callers run it off the main
    // thread. Unpacks into a scratch dir *next to* the installed app so the final swap is a
    // same-volume replaceItemAt (atomic, keeps a backup): any failure before it throws and leaves
    // the installed app untouched. ponytail: no progress bar, no delta updates — it's a 120K zip.
    static func downloadAndReplace(zip: URL = zipURL, app: URL) throws {
        let fm = FileManager.default
        let data = try Data(contentsOf: zip)
        let work = app.deletingLastPathComponent().appendingPathComponent(".claudewatch-update")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zipFile = work.appendingPathComponent("Claudewatch.zip")
        try data.write(to: zipFile)
        let p = Process()                                  // same tool build.sh packs it with
        p.launchPath = "/usr/bin/ditto"; p.arguments = ["-x", "-k", zipFile.path, work.path]
        try p.run(); p.waitUntilExit()
        let fresh = work.appendingPathComponent("Claudewatch.app")
        guard p.terminationStatus == 0,
              fm.fileExists(atPath: fresh.appendingPathComponent("Contents/MacOS/claudewatch").path) else {
            throw NSError(domain: "claudewatch", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "the downloaded archive isn't a Claudewatch.app"])
        }
        _ = try fm.replaceItemAt(app, withItemAt: fresh)
    }
    // Clicking the update notice. Always asks first — replacing the app and restarting it is not
    // something to do behind the user's back, even when they asked for auto-update.
    // The plugin lives in Claude Code's own cache and Claude Code updates it — the most we can
    // usefully do is hand over the command, so it's one paste away.
    @objc func copyPluginUpdateCommand() {
        let cmd = "/plugin marketplace update claudewatch"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
    }
    @objc func promptUpdate() {
        guard !newVersion.isEmpty else { return }
        guard appStale else {                       // only the plugin is behind
            let a = NSAlert()
            a.messageText = "Claude Code plugin update — v\(newVersion)"
            a.informativeText = "The app is current. Your claudewatch plugin is older; Claude Code updates it, not this app.\n\nRun in Claude Code:\n/plugin marketplace update claudewatch"
            a.addButton(withTitle: "Copy command"); a.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { copyPluginUpdateCommand() }
            return
        }
        guard Bundle.main.bundleIdentifier != nil else { return openReleases() }   // dev build: nothing to replace
        let a = NSAlert()
        a.messageText = "Update claudewatch to v\(newVersion)?"
        a.informativeText = "Downloads the release from GitHub, replaces this app, and restarts it."
            + (pluginStale ? "\n\nYour Claude Code plugin is also behind — update it separately with\n/plugin marketplace update claudewatch" : "")
        a.addButton(withTitle: "Update & restart")
        a.addButton(withTitle: "Open release page")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let app = Bundle.main.bundleURL
            DispatchQueue.global().async {
                do {
                    try AppDelegate.downloadAndReplace(app: app)
                    DispatchQueue.main.async { self.relaunchSelf() }
                } catch {
                    DispatchQueue.main.async { self.updateFailed(error) }
                }
            }
        case .alertSecondButtonReturn: openReleases()
        default: break
        }
    }
    func updateFailed(_ e: Error) {
        let a = NSAlert()
        a.messageText = "Update failed"
        a.informativeText = "\(e.localizedDescription)\n\nThe installed app is unchanged — you can download the update by hand."
        a.addButton(withTitle: "Open release page"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { openReleases() }
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
