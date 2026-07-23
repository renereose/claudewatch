// The window + controller. Owns the borderless floating panel, hosts the WKWebView, bridges
// JS <-> Swift (focus/cfg/fit/drag/quit messages), manages drag handles, and refreshes every 2s.
import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler {
    var web: WKWebView!
    var panel: NSPanel!
    var grips: [DragView] = []                       // drag handles (bubble: whole pill; list: bar gaps)

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

    func applyPref(_ p: [String: Any]) {            // native side-effects of settings
        if let op = (p["op"] as? NSNumber)?.doubleValue { opacity = max(0.2, min(1, op)) }
        panel?.level = ((p["onTop"] as? NSNumber)?.boolValue ?? true) ? .floating : .normal
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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
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
        web = WKWebView(frame: cv.bounds, configuration: cfg)
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
        if let pd = prefJSON.data(using: .utf8),                     // apply saved opacity + onTop
           let p = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any] { applyPref(p) }
        applyWindow()                        // apply persisted mode + opacity, pin to that corner
        panel.makeKeyAndOrderFront(nil)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.web.evaluateJavaScript("setCfg('\(self.mode)',\(self.prefJSON))")   // push prefs into the view
            self.refresh()
        }
    }
    func refresh() {
        let rows = scan()
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("render(\(json))")
    }
    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }   // red button quits
}
