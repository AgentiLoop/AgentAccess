import AgentAudit
import AXorcist
import Foundation
import AppKit

// MARK: - Select Option / Set State

extension AccessibilityService {

    /// Put a control into a named state and verify it — the accessibility
    /// equivalent of AppleScript's `click menu item "X" of menu 1 of pop up button 1`
    /// / `set value of checkbox 1 to 1` / `set value of slider 1 to 50`, in one call:
    /// - AXPopUpButton / AXMenuButton / AXComboBox: opens the menu, picks the item whose
    ///   title matches `option` (exact, then prefix, then contains — case-insensitive).
    /// - AXCheckBox / AXSwitch / AXRadioButton: `on`/`off` (also true/false/1/0/yes/no);
    ///   presses only if the current state differs, so it's idempotent (unlike click).
    /// - AXSlider / AXIncrementor: numeric value.
    /// - AXTextField / AXTextArea / AXSearchField: replaces the text.
    @MainActor
    public func selectOption(role: String?, title: String?, value: String?, appBundleId: String?, option: String) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "selectOption(role: \(role ?? "nil"), title: \(title ?? "nil"), option: \(option), app: \(appBundleId ?? "frontmost"))")
        guard role != nil || title != nil || value != nil else {
            return errorJSON("Provide role/title/value to identify the control")
        }
        guard let el = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) else {
            return errorJSON("Element not found: role=\(role ?? "any"), title=\(title ?? "any")")
        }
        let elRole = el.role() ?? ""
        if Self.isRestricted(elRole) {
            return errorJSON("Cannot interact with \(elRole) — disabled in Accessibility Access")
        }
        let label = [el.title(), el.descriptionText(), title].compactMap { $0 }.first { !$0.isEmpty } ?? elRole

        switch elRole {
        case "AXCheckBox", "AXSwitch", "AXRadioButton":
            return setToggle(el, label: label, option: option)
        case "AXSlider", "AXIncrementor", "AXLevelIndicator":
            guard let n = Double(option.trimmingCharacters(in: .whitespaces)) else {
                return errorJSON("\(elRole) needs a number, got '\(option)'")
            }
            guard el.setValue(NSNumber(value: n), forAttribute: "AXValue") else {
                return errorJSON("Could not set \(elRole) '\(label)' to \(option)")
            }
            let now = (el.value() as? NSNumber).map { "\($0)" } ?? "?"
            return successJSON(["message": "Set \(elRole) '\(label)' to \(now)", "value": now])
        case "AXTextField", "AXTextArea", "AXSearchField":
            guard el.setValue(option, forAttribute: "AXValue") else {
                return errorJSON("Could not set text of \(elRole) '\(label)'")
            }
            _ = try? el.performAction(.confirm)
            let now = el.value() as? String ?? ""
            if now != option { return errorJSON("Text set but field now reads '\(now)'") }
            return successJSON(["message": "Set text of '\(label)'", "value": now])
        case "AXComboBox":
            if el.setValue(option, forAttribute: "AXValue") {
                _ = try? el.performAction(.confirm)
                if let now = el.value() as? String, now.caseInsensitiveCompare(option) == .orderedSame {
                    return successJSON(["message": "Set combo box '\(label)' to '\(now)'", "value": now])
                }
            }
            return pickFromMenu(el, role: elRole, label: label, option: option)
        default:
            return pickFromMenu(el, role: elRole, label: label, option: option)
        }
    }

    @MainActor
    private func setToggle(_ el: Element, label: String, option: String) -> String {
        let o = option.lowercased().trimmingCharacters(in: .whitespaces)
        let want: Int
        switch o {
        case "on", "true", "1", "yes", "checked", "selected", "enable", "enabled": want = 1
        case "off", "false", "0", "no", "unchecked", "deselected", "disable", "disabled": want = 0
        default: return errorJSON("Toggle option must be on or off, got '\(option)'")
        }
        func state() -> Int { (el.value() as? NSNumber)?.intValue ?? 0 }
        if state() == want {
            return successJSON(["message": "'\(label)' already \(want == 1 ? "on" : "off")", "changed": false])
        }
        if el.role() == "AXRadioButton", want == 0 {
            return errorJSON("A radio button can't be turned off directly — select another option in its group")
        }
        if (try? el.performAction(.press)) == nil, (try? el.click()) == nil {
            return errorJSON("Could not press '\(label)'")
        }
        let deadline = Date().addingTimeInterval(1.5)
        while state() != want, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if state() != want {
            return errorJSON("Pressed '\(label)' but it is still \(state() == 1 ? "on" : "off")")
        }
        return successJSON(["message": "'\(label)' is now \(want == 1 ? "on" : "off")", "changed": true])
    }

    /// Open the element's menu and press the item matching `option`.
    @MainActor
    private func pickFromMenu(_ el: Element, role: String, label: String, option: String) -> String {
        func openMenu() -> Element? {
            func menuChild() -> Element? {
                el.children(strict: true)?.first { $0.role() == "AXMenu" }
            }
            if let m = menuChild() { return m }
            if (try? el.performAction(.press)) == nil { _ = try? el.performAction(.showMenu) }
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if let m = menuChild() { return m }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return nil
        }
        guard let menu = openMenu() else {
            return errorJSON("\(role) '\(label)' did not open a menu. Use click_element on it, then click the option.")
        }
        var items: [(title: String, el: Element)] = []
        for item in menu.children(strict: true) ?? [] where item.role() == "AXMenuItem" {
            if let t = item.title(), !t.isEmpty { items.append((t, item)) }
        }
        let want = option.lowercased().trimmingCharacters(in: .whitespaces)
        let match = items.first { $0.title.lowercased() == want }
            ?? items.first { $0.title.lowercased().hasPrefix(want) }
            ?? items.first { $0.title.lowercased().contains(want) }
        guard let pick = match else {
            // Close the menu so the app isn't left in a modal tracking loop.
            _ = try? menu.performAction(.cancel)
            let names = items.map(\.title).prefix(40).joined(separator: " | ")
            return errorJSON("No option '\(option)' in \(role) '\(label)'. Options: \(names)")
        }
        if pick.el.isEnabled() == false {
            _ = try? menu.performAction(.cancel)
            return errorJSON("Option '\(pick.title)' is disabled")
        }
        do {
            try pick.el.performAction(.press)
        } catch {
            _ = try? menu.performAction(.cancel)
            return errorJSON("Could not press option '\(pick.title)': \(error.localizedDescription)")
        }
        // The control updates asynchronously — wait (≤1s) until it shows the pick.
        func shown() -> String { (el.value() as? String) ?? el.title() ?? "" }
        let deadline = Date().addingTimeInterval(1.0)
        while shown() != pick.title, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let now = shown()
        var result: [String: Any] = ["message": "Selected '\(pick.title)' in \(role) '\(label)'", "selected": pick.title]
        if !now.isEmpty { result["value"] = now }
        return successJSON(result)
    }
}
