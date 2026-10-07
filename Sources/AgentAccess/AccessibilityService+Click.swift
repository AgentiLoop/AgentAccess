import AXorcist
import AppKit
import Foundation

extension AccessibilityService {

    // MARK: - Click with evidence

    /// Press `element` the way AppleScript's `click button "X"` does (AXPress, works
    /// off-screen and behind other windows, never moves the mouse), falling back to a
    /// real mouse click only when the element has no AXPress — and only after checking
    /// that the point under its center really is this element (scrolled into view
    /// first), so a mouse click never lands on a different element or another app.
    /// The result reports what changed: window, sheets, focus, web page URL, the
    /// element's own value/selection, or that it disappeared.
    /// `verify`: when an AXPress changed nothing visible, retry once with a mouse click.
    @MainActor
    func pressWithEvidence(_ element: Element, verify: Bool) -> String {
        let pid = element.pid() ?? 0
        let isWeb = Self.isInWebArea(element)
        let target = elementProperties(element)
        let before = Self.clickSnapshot(pid: pid, target: element, web: isWeb)

        var method = ""
        var notes: [String] = []
        if element.isActionSupported(AXAction.press.rawValue), (try? element.performAction(.press)) != nil {
            method = "AXPress"
        } else {
            if let blocked = Self.mouseClickBlocker(element, pid: pid) {
                return errorJSON("Not clicked: \(element.role() ?? "element") '\(Self.label(element))' has no AXPress and a mouse click would miss it — \(blocked). Scroll it into view (scroll_to_element) or bring its window forward, then retry.")
            }
            do { try element.click() } catch {
                return errorJSON("Element is not clickable through accessibility (no AXPress, mouse click failed: \(error)) for \(element.role() ?? "unknown") '\(Self.label(element))'.")
            }
            method = "mouse click"
        }

        var after = Self.waitForChange(from: before, pid: pid, target: element, web: isWeb)
        if after == before, verify, method == "AXPress" {
            if let blocked = Self.mouseClickBlocker(element, pid: pid) {
                notes.append("AXPress changed nothing visible; mouse-click retry skipped — \(blocked)")
            } else if (try? element.click()) != nil {
                method = "AXPress, then mouse click (AXPress changed nothing visible)"
                after = Self.waitForChange(from: before, pid: pid, target: element, web: isWeb)
            }
        }

        var info: [String: Any] = [
            "message": method == "AXPress" ? "Pressed element" : "Clicked element",
            "method": method,
            "element": target,
            "before": before.dictionary,
            "after": after.dictionary,
            "changed": before.changes(to: after) ?? "nothing visible changed (the click may still have worked, e.g. a command with no UI — check with read_text)",
        ]
        if !notes.isEmpty { info["note"] = notes.joined(separator: "; ") }
        return successJSON(info)
    }

    // MARK: - Snapshot

    struct ClickSnapshot: Equatable {
        var focus = FocusSnapshot()
        var url = ""
        var targetState = ""
        var texts: [String] = []
        var dictionary: [String: Any] {
            var d = focus.dictionary
            if !url.isEmpty { d["url"] = url }
            d["element_state"] = targetState
            return d
        }
        func changes(to after: ClickSnapshot) -> String? {
            var c: [String] = []
            let (b, a) = (focus, after.focus)
            if b.frontApp != a.frontApp { c.append("frontmost app → \(a.frontApp)") }
            if b.window != a.window { c.append("window → \"\(a.window)\"") }
            if b.windowCount != a.windowCount { c.append("windows \(b.windowCount) → \(a.windowCount)") }
            if b.sheetCount != a.sheetCount { c.append("sheets \(b.sheetCount) → \(a.sheetCount)") }
            if url != after.url { c.append("page → \(after.url.isEmpty ? "(none)" : after.url)") }
            if targetState != after.targetState { c.append("element → \(after.targetState)") }
            if b.focus != a.focus { c.append("focus → \(a.focus)") }
            if b.value != a.value { c.append("focused value changed") }
            if texts != after.texts {
                let new = after.texts.filter { !texts.contains($0) }.prefix(3).map { "\"\($0)\"" }
                c.append(new.isEmpty ? "window text changed" : "window text → \(new.joined(separator: ", "))")
            }
            return c.isEmpty ? nil : c.joined(separator: "; ")
        }
    }

    @MainActor
    static func clickSnapshot(pid: pid_t, target: Element, web: Bool) -> ClickSnapshot {
        var s = ClickSnapshot()
        s.focus = focusSnapshot(pid: pid)
        if web { s.url = webURL(pid: pid) } else { s.texts = windowTexts(pid: pid) }
        s.targetState = elementState(target)
        return s
    }

    @MainActor
    static func waitForChange(from before: ClickSnapshot, pid: pid_t, target: Element, web: Bool) -> ClickSnapshot {
        var after = before
        let start = Date()
        repeat {
            Thread.sleep(forTimeInterval: 0.1)
            after = clickSnapshot(pid: pid, target: target, web: web)
        } while after == before && Date().timeIntervalSince(start) < (web ? 1.5 : 1.0)
        return after
    }

    /// "value=1, selected" / "gone (closed or replaced)".
    @MainActor
    static func elementState(_ el: Element) -> String {
        guard el.role() != nil else { return "gone (closed or replaced)" }
        var parts: [String] = []
        if let v = el.value() {
            let s = String(describing: v)
            if !s.isEmpty { parts.append("value=\(s.prefix(80))") }
        }
        if el.attribute(Attribute<Bool>("AXSelected")) == true { parts.append("selected") }
        if el.attribute(Attribute<Bool>("AXExpanded")) == true { parts.append("expanded") }
        if el.isEnabled() == false { parts.append("disabled") }
        return parts.isEmpty ? "present" : parts.joined(separator: ", ")
    }

    /// URL of the web page in the app's focused window (AXWebArea's AXURL).
    @MainActor
    static func webURL(pid: pid_t) -> String {
        guard let win = Element.application(for: pid)?.focusedWindow() else { return "" }
        var queue: [Element] = [win]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let el = queue.removeFirst()
            visited += 1
            if el.role() == "AXWebArea" { return el.url()?.absoluteString ?? "" }
            queue.append(contentsOf: el.children(strict: true) ?? [])
        }
        return ""
    }

    /// Static text in the focused window (labels, displays, status lines) — catches
    /// effects like a calculator display or a status label that focus/value miss.
    @MainActor
    static func windowTexts(pid: pid_t) -> [String] {
        guard let win = Element.application(for: pid)?.focusedWindow() else { return [] }
        var queue: [Element] = [win]
        var texts: [String] = []
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let el = queue.removeFirst()
            visited += 1
            if el.role() == "AXStaticText", let v = el.value() as? String, !v.isEmpty {
                texts.append(String(v.prefix(80)))
            }
            queue.append(contentsOf: el.children(strict: true) ?? [])
        }
        return texts
    }
    // MARK: - Mouse safety

    /// nil when a mouse click at the element's center will hit the element itself
    /// (or something inside it); otherwise why it wouldn't. Scrolls it visible once.
    @MainActor
    static func mouseClickBlocker(_ el: Element, pid: pid_t) -> String? {
        var reason = hitTestProblem(el, pid: pid)
        if reason != nil, el.isActionSupported("AXScrollToVisible") {
            _ = try? el.performAction("AXScrollToVisible")
            Thread.sleep(forTimeInterval: 0.3)
            reason = hitTestProblem(el, pid: pid)
        }
        return reason
    }

    @MainActor
    static func hitTestProblem(_ el: Element, pid: pid_t) -> String? {
        guard let f = el.frame(), f.width > 0, f.height > 0 else { return "it has no on-screen frame" }
        let point = CGPoint(x: f.midX, y: f.midY)
        // AX coordinates are top-left based on the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        if !NSScreen.screens.contains(where: { $0.frame.contains(cocoaPoint) }) { return "its center is off-screen" }
        // Must also be inside the visible part of every enclosing scroll area and its window.
        var anc = el.parent()
        for _ in 0..<40 {
            guard let a = anc else { break }
            let r = a.role()
            if r == "AXScrollArea" || r == "AXWindow", let af = a.frame(), af.width > 0, !af.contains(point) {
                return r == "AXWindow" ? "its center is outside its window" : "it is scrolled out of view"
            }
            if r == "AXWindow" || r == "AXApplication" { break }
            anc = a.parent()
        }
        guard let hit = Element.elementAtPoint(point) else { return nil }   // can't tell — allow
        if let hp = hit.pid(), hp != pid {
            let owner = NSRunningApplication(processIdentifier: hp)?.localizedName ?? "another app"
            return "\(owner) is covering it"
        }
        // The hit element is the target, inside it, or contains it (target not hittable itself).
        var cur: Element? = hit
        for _ in 0..<25 { guard let c = cur else { break }; if c == el { return nil }; cur = c.parent() }
        cur = el.parent()
        for _ in 0..<25 { guard let c = cur else { break }; if c == hit { return nil }; cur = c.parent() }
        return "the point under its center is \(hit.role() ?? "?") '\(label(hit))' (scrolled out of view or covered)"
    }

    @MainActor
    static func label(_ el: Element) -> String {
        let s = el.title() ?? el.descriptionText() ?? (el.value() as? String) ?? ""
        return String(s.prefix(60))
    }
}
