// Native drag handle — WKWebView eats background drags, so we need this. Distinguishes a
// click (no movement → onClick, used to expand the bubble) from a drag (moves the window).
import Cocoa

class DragView: NSView {
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    override func mouseDown(with e: NSEvent) {
        guard let win = window else { return }
        let start = NSEvent.mouseLocation, origin = win.frame.origin
        var moved = false
        while let ev = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                       until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if ev.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation, dx = now.x - start.x, dy = now.y - start.y
            if abs(dx) > 3 || abs(dy) > 3 { if !moved { NSCursor.closedHand.push() }; moved = true }
            if moved { win.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy)) }
        }
        if moved { NSCursor.pop(); onMoved?() } else { onClick?() }
    }
    // Tracking area (not cursor rects) — reliable on a borderless non-activating panel.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }
    override func cursorUpdate(with e: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with e: NSEvent) { NSCursor.openHand.set() }
}
