import AppKit
import Carbon.HIToolbox

/// Global hotkeys. Modifier-only chords (left+right ⌘) and double-tap use NSEvent
/// global monitors (need Accessibility); regular combos use Carbon RegisterEventHotKey.
final class HotkeyManager {
    var onTrigger: (() -> Void)?

    private var monitors: [Any] = []
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private var chordFired = false
    private var cmdDownAt: TimeInterval = 0
    private var cmdDownClean = false
    private var lastTapUp: TimeInterval = 0

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK)
    private let leftCmd: UInt = 0x08
    private let rightCmd: UInt = 0x10
    private let leftOpt: UInt = 0x20
    private let rightOpt: UInt = 0x40

    func start(kind: HotkeyKind, custom: CustomHotkey?) {
        stop()
        switch kind {
        case .leftRightCommand: watchChord(leftCmd, rightCmd)
        case .leftRightOption: watchChord(leftOpt, rightOpt)
        case .doubleCommand: watchDoubleTap()
        case .custom:
            if let c = custom { registerCarbon(c) } else { watchChord(leftCmd, rightCmd) }
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
        chordFired = false
        cmdDownClean = false
        lastTapUp = 0
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in handler(e); return e }) {
            monitors.append(l)
        }
    }

    private func watchChord(_ a: UInt, _ b: UInt) {
        addMonitor(.flagsChanged) { [weak self] e in
            guard let self else { return }
            let raw = e.modifierFlags.rawValue
            let aDown = (raw & a) != 0
            let bDown = (raw & b) != 0
            if aDown && bDown {
                if !self.chordFired {
                    self.chordFired = true
                    self.fire()
                }
            } else if !aDown && !bDown {
                self.chordFired = false
            }
        }
    }

    private func watchDoubleTap() {
        addMonitor(.flagsChanged) { [weak self] e in
            guard let self else { return }
            let flags = e.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])
            let now = ProcessInfo.processInfo.systemUptime
            if flags == .command {
                self.cmdDownAt = now
                self.cmdDownClean = true
            } else if flags.isEmpty, self.cmdDownClean, now - self.cmdDownAt < 0.3 {
                self.cmdDownClean = false
                if now - self.lastTapUp < 0.45 {
                    self.lastTapUp = 0
                    self.fire()
                } else {
                    self.lastTapUp = now
                }
            } else {
                self.cmdDownClean = false
            }
        }
        // Any real key press in between cancels the tap sequence (⌘C, ⌘V ...)
        addMonitor(.keyDown) { [weak self] _ in
            self?.cmdDownClean = false
            self?.lastTapUp = 0
        }
    }

    private func registerCarbon(_ c: CustomHotkey) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.fire() }
            return OSStatus(0)
        }, 1, &spec, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4150_5348), id: 1) // 'APSH'
        RegisterEventHotKey(c.keyCode,
                            Self.carbonModifiers(NSEvent.ModifierFlags(rawValue: c.modifiers)),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func label(for e: NSEvent, modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let named: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
                                       123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                       98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let n = named[e.keyCode] {
            s += n
        } else if let c = e.charactersIgnoringModifiers, !c.isEmpty {
            s += c.uppercased()
        } else {
            s += "#\(e.keyCode)"
        }
        return s
    }

    fileprivate func fire() {
        onTrigger?()
    }
}
