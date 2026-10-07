import AgentAudit
import AXorcist
import AppKit
import Foundation

extension AccessibilityService {
    static let textInputRoles = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"]

    // MARK: - Type Text Into Element

    /// Put `text` into a text input and check that it arrived.
    /// Native fields: AXValue is set and read back. Web fields (Safari/Chrome
    /// inputs, textareas, contenteditable) and any field that ignores AXValue:
    /// the app is brought forward, the field focused, existing text selected and
    /// replaced by real keystrokes — so page scripts see input events, like a
    /// user typing. Success is only reported when the field's value matches.
    @MainActor
    public func typeTextIntoElement(role: String?, title: String?, text: String, appBundleId: String?, verify: Bool = true) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "typeTextIntoElement(role: \(role ?? "nil"), title: \(title ?? "nil"), text: \(text.count) chars)")

        // With no role, a title like "Full name" can match the label text before
        // the field it names — try the text-input roles first.
        var found: Element?
        if role == nil {
            for r in Self.textInputRoles {
                if let e = findAXElement(role: r, title: title, value: nil, appBundleId: appBundleId) { found = e; break }
            }
        }
        if found == nil { found = findAXElement(role: role, title: title, value: nil, appBundleId: appBundleId) }
        guard let field = found else {
            // List the text inputs that actually exist so the LLM can retry
            // with a real title instead of guessing again.
            var hints: [String] = []
            if let bid = resolveBundleId(appBundleId),
               let app = RunningApplicationHelper.applications(withBundleIdentifier: bid).first,
               let appElement = Element.application(for: app) {
                for r in Self.textInputRoles {
                    hints += interactiveTitles(in: appElement, role: r, limit: 8).map { "\(r) '\($0)'" }
                }
            }
            var err = "Element not found for typing (role=\(role ?? "any"), title=\(title ?? "any"))."
            if !hints.isEmpty { err += " Text inputs present: \(hints.joined(separator: " | "))" }
            return errorJSON(err)
        }

        let secure = field.role() == "AXSecureTextField" || field.subrole() == "AXSecureTextField"
        let inWeb = Self.isInWebArea(field)
        var info: [String: Any] = ["text_length": text.count]

        func matches() -> Bool { Self.normalized(Self.currentText(field)) == Self.normalized(text) }

        // Native: AXValue is instant and exact. Web: skip it — WebKit accepts the
        // set and ignores it, and a set value fires no input events for page scripts.
        if !inWeb, field.setValue(text, forAttribute: "AXValue") {
            Thread.sleep(forTimeInterval: 0.05)
            if !verify || secure || matches() {
                info["message"] = "Text set via AXValue"
                info["method"] = "element_setValue"
                info["verified"] = verify && !secure
                info["element"] = elementProperties(field)
            return successJSON(info)
            }
        }

        // Keystrokes go to the frontmost app's focused element.
        if let pid = field.pid(), let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
            if let appEl = Element.application(for: pid) { _ = appEl.activate() }
            let start = Date()
            while !app.isActive, Date().timeIntervalSince(start) < 1.5 { Thread.sleep(forTimeInterval: 0.05) }
        }
        if field.isFocused() != true, !field.setValue(true, forAttribute: "AXFocused") || field.isFocused() == false {
            try? field.click()
        }
        Thread.sleep(forTimeInterval: 0.15)
        do {
            if !(Self.currentText(field) ?? "").isEmpty || secure {
                try Element.performHotkey(keys: ["cmd", "a"], holdDuration: 0.05)
                Thread.sleep(forTimeInterval: 0.05)
                try Element.typeKey(.delete)
                Thread.sleep(forTimeInterval: 0.05)
            }
            try Element.typeText(text)
        } catch {
            return errorJSON("Type failed: \(error.localizedDescription)")
        }
        info["method"] = "keystrokes"
        if !verify || secure {
            info["message"] = "Typed \(text.count) characters"
            info["verified"] = false
            info["element"] = elementProperties(field)
            return successJSON(info)
        }
        // Web views update their AX tree asynchronously — poll briefly.
        let start = Date()
        repeat {
            if matches() {
                info["message"] = "Typed \(text.count) characters"
                info["verified"] = true
                info["element"] = elementProperties(field)
            return successJSON(info)
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date().timeIntervalSince(start) < 1.5
        let actual = Self.currentText(field) ?? ""
        return errorJSON("Typed \(text.count) characters but the field now contains \"\(actual.prefix(200))\" (expected \"\(text.prefix(200))\"). Keystrokes may have gone to another element — check the field is visible and enabled, then retry.")
    }

    /// Value of a text input; contenteditable web areas fall back to their text children.
    @MainActor
    static func currentText(_ el: Element) -> String? {
        if let s = el.value() as? String, !s.isEmpty { return s }
        guard isInWebArea(el) else { return el.value() as? String }
        var parts: [String] = []
        func collect(_ e: Element, depth: Int) {
            guard depth > 0 else { return }
            for c in e.children(strict: true) ?? [] {
                if c.role() == "AXStaticText", let s = c.value() as? String { parts.append(s) }
                collect(c, depth: depth - 1)
            }
        }
        collect(el, depth: 6)
        return parts.joined()
    }

    static func normalized(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    static func isInWebArea(_ el: Element) -> Bool {
        var cur = el.parent()
        var hops = 0
        while let p = cur, hops < 60 {
            let r = p.role()
            if r == "AXWebArea" { return true }
            if r == "AXWindow" || r == "AXApplication" { return false }
            cur = p.parent()
            hops += 1
        }
        return false
    }
}
