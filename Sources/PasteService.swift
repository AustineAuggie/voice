import AppKit
import ApplicationServices

struct PasteTarget {
    let pid: pid_t
    let element: AXUIElement
    let selection: CFRange?
}

enum PasteService {
    private struct Receipt {
        let target: PasteTarget
        let proof: TextChangeProof
        let created = Date()
    }
    private static var receipt: Receipt?
    private static var insertionID = UUID()
    static var onReceiptChange: (() -> Void)?
    static var canRestore: Bool { receipt != nil }
    static var lastFailure = ""
    static func clearReceipt() { insertionID = UUID(); receipt = nil; onReceiptChange?() }
    private static var clipboardLease: (changeCount: Int, saved: [[NSPasteboard.PasteboardType: Data]])?

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        return value as? String == "AXSecureTextField"
    }

    static func selection(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range) else { return nil }
        return range
    }

    static func selectionMatches(_ target: PasteTarget, current: AXUIElement) -> Bool {
        // Some web editors don't expose a caret range. Their focused element is
        // still checked, but automatic insertion is necessarily best-effort.
        guard let original = target.selection else { return true }
        guard let now = selection(current) else { return false }
        return original.location == now.location && original.length == now.length
    }

    static func capture() -> PasteTarget? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focusedElement(pid: app.processIdentifier), !isSecure(element) else { return nil }
        return PasteTarget(pid: app.processIdentifier, element: element, selection: selection(element))
    }

    @discardableResult static func copy(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }

    private static func count(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }
    private static func text(_ element: AXUIElement, range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0, range.length <= 16000 else { return nil }
        if range.length == 0 { return "" }
        var bounds = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &bounds) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else { return nil }
        return value as? String
    }
    private static func context(_ element: AXUIElement, at range: CFRange) -> (String?, String?) {
        let beforeCount = min(24, max(0, range.location))
        let before = text(element, range: NSRange(location: range.location - beforeCount, length: beforeCount))
        let end = range.location + range.length
        let afterCount = count(element).map { min(24, max(0, $0 - end)) } ?? 1
        return (before, text(element, range: NSRange(location: end, length: afterCount)))
    }
    private static func matches(_ item: Receipt) -> Bool {
        guard AXIsProcessTrusted(), Date().timeIntervalSince(item.created) < 300,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == item.target.pid,
              let current = focusedElement(pid: item.target.pid), CFEqual(current, item.target.element), !isSecure(current),
              let selection = selection(current) else { return false }
        let p = item.proof
        return p.matches(text: text(current, range: p.range),
            prefix: text(current, range: NSRange(location: p.location - (p.prefix as NSString).length, length: (p.prefix as NSString).length)),
            suffix: text(current, range: NSRange(location: p.end, length: (p.suffix as NSString).length)),
            selection: NSRange(location: selection.location, length: selection.length), length: count(current))
    }
    // Success means the paste was sent. A separate read-back confirms whether
    // exact, guarded Undo / Restore original is available in this editor.
    static func insert(_ text: String, into target: PasteTarget?, restoreClipboard: Bool) -> Bool {
        guard AXIsProcessTrusted() else { lastFailure = "Allow Device Control and Data Access (Accessibility) in System Settings."; return false }
        guard let target = target else { lastFailure = "Text saved. Click your text field, then choose Retry paste from the menu."; return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let current = focusedElement(pid: target.pid), CFEqual(current, target.element),
              !isSecure(current), selectionMatches(target, current: current) else {
            lastFailure = "Text saved. The field or cursor changed; use Copy or Retry paste."; return false
        }
        let range = selection(current)
        let surroundings = range.map { context(current, at: $0) } ?? (nil, nil)
        let rendered = InsertionSpacing.prepare(text, before: surroundings.0, after: surroundings.1)
        var proof: TextChangeProof?
        if let range = range, let before = surroundings.0, let after = surroundings.1,
           let previous = self.text(current, range: NSRange(location: range.location, length: range.length)) {
            proof = TextChangeProof(location: range.location, inserted: rendered, previous: previous,
                prefix: before, suffix: after, resultingLength: count(current).map { $0 - range.length + (rendered as NSString).length })
        }
        guard postPaste(rendered, restoreClipboard: restoreClipboard) else { lastFailure = "Could not access the clipboard. Your text is saved in Voice."; return false }
        lastFailure = ""; receipt = nil; let token = UUID(); insertionID = token; onReceiptChange?()
        if let proof = proof {
            let candidate = Receipt(target: target, proof: proof)
            for delay in [0.12, 0.35, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard insertionID == token, receipt == nil, matches(candidate) else { return }
                    receipt = candidate; onReceiptChange?()
                }
            }
        }
        return true
    }
    static func restore(original: String? = nil, restoreClipboard: Bool, completion: @escaping (Bool, String) -> Void) {
        guard let item = receipt else { completion(false, "This editor did not confirm the insertion. Copy the original text from History instead."); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != item.target.pid {
            NSRunningApplication(processIdentifier: item.target.pid)?.activate(options: .activateIgnoringOtherApps)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard matches(item) else { receipt = nil; onReceiptChange?(); completion(false, "The text or cursor changed. No text was replaced."); return }
            var range = CFRange(location: item.proof.range.location, length: item.proof.range.length)
            guard let value = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(item.target.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                completion(false, "This editor cannot select the inserted text safely. Use Copy original instead."); return
            }
            guard let selected = selection(item.target.element), selected.location == range.location, selected.length == range.length,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == item.target.pid,
                  let focused = focusedElement(pid: item.target.pid), CFEqual(focused, item.target.element) else {
                completion(false, "The editor did not confirm the selection. No replacement was sent."); return
            }
            let replacement = original.map { InsertionSpacing.prepare($0, before: item.proof.prefix, after: item.proof.suffix) } ?? item.proof.previous
            let sent: Bool
            if replacement.isEmpty {
                if let source = CGEventSource(stateID: .privateState),
                   let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                   let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap); sent = true
                } else { sent = false }
            } else { sent = postPaste(replacement, restoreClipboard: restoreClipboard) }
            insertionID = UUID(); receipt = nil; onReceiptChange?()
            completion(sent, sent ? (original == nil ? "Undo sent." : "Original wording sent.") : "Could not send the replacement. Your original text is available in History.")
        }
    }
    private static func postPaste(_ text: String, restoreClipboard: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        let board = NSPasteboard.general
        let previousLease = clipboardLease
        let saved: [[NSPasteboard.PasteboardType: Data]] = restoreClipboard && previousLease?.changeCount == board.changeCount ? previousLease!.saved : restoreClipboard ? (board.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
        } : []
        guard copy(text) else { return false }
        let writtenChangeCount = board.changeCount
        clipboardLease = restoreClipboard ? (writtenChangeCount, saved) : nil
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        if restoreClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // A later copy always wins; never overwrite a newer clipboard item.
                guard board.changeCount == writtenChangeCount, clipboardLease?.changeCount == writtenChangeCount else { return }
                clipboardLease = nil
                board.clearContents()
                let items = saved.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        return true
    }
}
