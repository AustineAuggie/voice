import AppKit
import ApplicationServices

final class HotkeyMonitor {
    var onAction: ((KeyAction) -> Void)?
    var onEscape: (() -> Void)?
    var onTyping: (() -> Void)?
    var onLost: (() -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var state = HoldShortcut()

    var shortcut: Shortcut {
        get { state.shortcut }
        set { state.reset(); state.shortcut = newValue }
    }

    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
            place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.state.reset()
                    monitor.onLost?()
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let kind: KeyInput
                switch type {
                case .flagsChanged: kind = .flags
                case .keyDown: kind = .down
                case .keyUp: kind = .up
                default: return Unmanaged.passUnretained(event)
                }
                let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if type == .keyDown && code == 53 { monitor.onEscape?() }
                else if type == .keyDown && code != monitor.shortcut.keyCode { monitor.onTyping?() }
                let action = monitor.state.consume(kind,
                    code: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                    flags: event.flags.rawValue,
                    repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                if action != .none { monitor.onAction?(action) }
                // Never swallow a user's key event or disable normal Option shortcuts.
                return Unmanaged.passUnretained(event)
            }, userInfo: context) else { return false }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    func resetHold() { state.reset() }

    func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil; runLoopSource = nil; state.reset()
    }
    deinit { stop() }
}
