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
    /// `submit`: then press Return in the field (AppleScript `set value of text
    /// field … ` + `keystroke return`) — address bars, search fields, single-line
    /// forms — and report what changed.
    @MainActor
    public func typeTextIntoElement(role: String?, title: String?, text: String, appBundleId: String?, verify: Bool = true, submit: Bool = false) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "typeTextIntoElement(role: \(role ?? "nil"), title: \(title ?? "nil"), text: \(text.count) chars, submit: \(submit))")

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

        /// Keystrokes go to the frontmost app's focused element: bring the
        /// field's app forward and focus the field.
        func activateAndFocus() -> Bool {
            guard let pid = field.pid(), let app = NSRunningApplication(processIdentifier: pid) else { return false }
            if !app.isActive {
                if let appEl = Element.application(for: pid) { _ = appEl.activate() }
                app.activate()
                let start = Date()
                while !app.isActive, Date().timeIntervalSince(start) < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
            if field.isFocused() != true, !field.setValue(true, forAttribute: "AXFocused") || field.isFocused() == false {
                try? field.click()
            }
            Thread.sleep(forTimeInterval: 0.15)
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }

        func replaceByKeystrokes() throws {
            if !(Self.currentText(field) ?? "").isEmpty || secure {
                try Element.performHotkey(keys: ["cmd", "a"], holdDuration: 0.05)
                Thread.sleep(forTimeInterval: 0.05)
                try Element.typeKey(.delete)
                Thread.sleep(forTimeInterval: 0.05)
            }
            try Element.typeText(text)
        }

        func waitForMatch(_ seconds: TimeInterval) -> Bool {
            let start = Date()
            repeat {
                if matches() { return true }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date().timeIntervalSince(start) < seconds
            return false
        }

        /// Success, optionally followed by Return in the field.
        func finish(_ result: [String: Any]) -> String {
            var info = result
            info["element"] = elementProperties(field)
            guard submit else { return successJSON(info) }
            guard let pid = field.pid(), activateAndFocus() else {
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
                return errorJSON("Text entered, but the field's app could not be brought to the front (\(front) is frontmost) — Return was NOT pressed.")
            }
            // Focusing can reset a field (Safari's address field shows the
            // current URL again when it gains focus) — put the text back.
            if !secure, !matches() {
                do { try replaceByKeystrokes() } catch {
                    return errorJSON("Re-typing after focus failed: \(error.localizedDescription) — Return was NOT pressed.")
                }
                if !waitForMatch(1.0) {
                    return errorJSON("After focusing, the field contains \"\((Self.currentText(field) ?? "").prefix(200))\" instead of the text — Return was NOT pressed.")
                }
            }
            let before = Self.focusSnapshot(pid: pid)
            do { try Element.typeKey(.return) } catch {
                return errorJSON("Text entered but pressing Return failed: \(error.localizedDescription)")
            }
            var after = before
            let start = Date()
            repeat {
                Thread.sleep(forTimeInterval: 0.1)
                after = Self.focusSnapshot(pid: pid)
            } while after == before && Date().timeIntervalSince(start) < 1.5
            info["submitted"] = true
            info["message"] = "\(info["message"] as? String ?? "Text entered"), then pressed Return"
            info["changed"] = Self.describeChanges(before: before, after: after)
            return successJSON(info)
        }

        // Native: AXValue is instant and exact. Web: skip it — WebKit accepts the
        // set and ignores it, and a set value fires no input events for page scripts.
        // Submit: skip it too — a set AXValue bypasses the field editor, so Return
        // acts on the old text (Safari's address field reloaded about:blank).
        if !inWeb, !submit, field.setValue(text, forAttribute: "AXValue") {
            Thread.sleep(forTimeInterval: 0.05)
            if !verify || secure || matches() {
                info["message"] = "Text set via AXValue"
                info["method"] = "element_setValue"
                info["verified"] = verify && !secure
                return finish(info)
            }
        }

        _ = activateAndFocus()
        do {
            try replaceByKeystrokes()
        } catch {
            return errorJSON("Type failed: \(error.localizedDescription)")
        }
        info["method"] = "keystrokes"
        if !verify || secure {
            info["message"] = "Typed \(text.count) characters"
            info["verified"] = false
            return finish(info)
        }
        // Web views update their AX tree asynchronously — poll briefly.
        if waitForMatch(1.5) {
            info["message"] = "Typed \(text.count) characters"
            info["verified"] = true
            return finish(info)
        }
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
