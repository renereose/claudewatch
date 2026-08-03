// A global hotkey, so jumping to the session that needs you doesn't require looking at the HUD.
// Carbon's RegisterEventHotKey — not NSEvent.addGlobalMonitorForEvents, which needs Accessibility
// trust and would put a system permission prompt in front of a convenience feature. Carbon needs
// none, and works from an LSUIElement accessory app.
import Carbon.HIToolbox
import Foundation

// ponytail: one hotkey, fixed chord. A recorder UI is the upgrade path if ⌃⌥⌘J collides.
private var handler: (() -> Void)?
private var hotKeyRef: EventHotKeyRef?
private var installed = false        // InstallEventHandler is additive — do it once, ever

// Register (or, with fn == nil, unregister) the chord. Idempotent — safe to call on every
// settings change; only the registration is torn down and rebuilt, never the event handler.
// Returns false if the chord couldn't be claimed (another app already owns it) — a hotkey that
// silently does nothing is worse than one that says why.
@discardableResult
func setHotkey(key: UInt32 = UInt32(kVK_ANSI_J),
               mods: UInt32 = UInt32(controlKey | optionKey | cmdKey),
               _ fn: (() -> Void)?) -> Bool {
    if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    handler = fn
    guard fn != nil else { return true }
    if !installed {
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            handler?()
            return noErr
        }, 1, &spec, nil, nil)
    }
    let id = EventHotKeyID(signature: OSType(0x4357), id: 1)   // 'CW'
    let err = RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    if err != noErr {
        FileHandle.standardError.write(Data("claudewatch: ⌃⌥⌘J is taken by another app (\(err))\n".utf8))
        handler = nil
        return false
    }
    return true
}
