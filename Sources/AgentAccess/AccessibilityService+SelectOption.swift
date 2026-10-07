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
            guard Double(option.trimmingCharacters(in: .whitespaces)) != nil else {
                return errorJSON("\(elRole) needs a number, got '\(option)'")
            }
            // Same path as set_properties: set, read back, step with AXIncrement/AXDecrement if ignored.
            let r = setAXProperty(el, key: "AXValue", value: option)
            let status = r["status"] as? String ?? "failed"
            let now = r["after"].map { "\($0)" } ?? "?"
            guard ["set", "adjusted", "unchanged"].contains(status) else {
                return errorJSON("Could not set \(elRole) '\(label)' to \(option): \(r["error"] as? String ?? status)")
            }
            var out: [String: Any] = ["message": "Set \(elRole) '\(label)' to \(now)", "value": now, "status": status]
            if let via = r["via"] { out["via"] = via }
            if let note = r["note"] { out["note"] = note }
            return successJSON(out)
        case "AXTextField", "AXTextArea", "AXSearchField":
            guard el.setValue(option, forAttribute: "AXValue") else {
                return errorJSON("Could not set text of \(elRole) '\(label)'")
            }
            _ = try? el.performAction(.confirm)
            let now = el.value() as? String ?? ""
            if now != option { return errorJSON("Text set but field now reads '\(now)'") }
            return successJSON(["message": "Set text of '\(label)'", "value": now])
        case "AXRadioGroup", "AXTabGroup":
            return pickChild(el, role: elRole, label: label, option: option)
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

    /// Case-insensitive match on a menu/option title: exact, then prefix, then contains.
    /// "..." and "…" are treated alike so "Save As..." matches "Save As…".
    private static func bestMatch<T>(_ items: [(title: String, el: T)], _ option: String) -> (title: String, el: T)? {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "…", with: "...").lowercased().trimmingCharacters(in: .whitespaces)
        }
        let want = norm(option)
        return items.first { norm($0.title) == want }
            ?? items.first { norm($0.title).hasPrefix(want) }
            ?? items.first { norm($0.title).contains(want) }
    }

    /// A pop-up menu the app has open on screen but doesn't list as a child of the control
    /// (Safari/WebKit `<select>` menus): find the app's pop-up-menu-level window and
    /// hit-test inside it, then walk up to the AXMenu.
    @MainActor
    static func onScreenPopUpMenu(pid: pid_t?) -> Element? {
        guard let pid,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == menuLevel,
                  let bd = w[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: bd as! CFDictionary),
                  frame.height > 8 else { continue }
            var y = frame.minY + 6
            while y < frame.maxY {
                var cur = Element.elementAtPoint(CGPoint(x: frame.midX, y: y))
                for _ in 0..<4 {
                    guard let c = cur else { break }
                    if c.role() == "AXMenu" { return c }
                    cur = c.parent()
                }
                y += 12
            }
        }
        return nil
    }

    /// Open the element's menu and press the item matching `option`.
    /// `option` may be a path into submenus: "Text > Bold" picks "Bold" in the "Text" submenu.
    @MainActor
    func pickFromMenu(_ el: Element, role: String, label: String, option: String) -> String {
        let pid = el.pid() ?? 0
        let isWeb = Self.isInWebArea(el)
        // Menu items: titled AXMenuItems; Chrome web <select> items have an empty title and
        // carry the text in AXValue, and its <optgroup>s are AXGroups holding more items.
        func items(of menu: Element) -> [(title: String, el: Element)] {
            var out: [(title: String, el: Element)] = []
            for item in menu.children(strict: true) ?? [] {
                switch item.role() {
                case "AXMenuItem":
                    let t = [item.title(), item.value() as? String].compactMap { $0 }.first { !$0.isEmpty }
                    if let t { out.append((t, item)) }
                case "AXGroup":
                    out += items(of: item)
                default: break
                }
            }
            return out
        }
        func openMenu() -> Element? {
            func menuChild() -> Element? {
                el.children(strict: true)?.first { $0.role() == "AXMenu" }
            }
            // An on-screen menu only counts if it lists the control's current value —
            // otherwise it is some other menu (e.g. a page context menu).
            func onScreen() -> Element? {
                guard let m = Self.onScreenPopUpMenu(pid: pid) else { return nil }
                if let cur = el.value() as? String, !cur.isEmpty,
                   !items(of: m).contains(where: { $0.title == cur }) { return nil }
                return m
            }
            if let m = menuChild() { return m }
            if el.isActionSupported(AXAction.press.rawValue) {
                _ = try? el.performAction(.press)
            } else if isWeb {
                // Chrome <select>: no AXPress, and AXShowMenu opens the page context menu.
                // The popup only opens in the front app, so bring it forward for the mouse click.
                if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
                    if let appEl = Element.application(for: pid) { _ = appEl.activate() }
                    app.activate()
                    let start = Date()
                    while !app.isActive, Date().timeIntervalSince(start) < 2 { Thread.sleep(forTimeInterval: 0.05) }
                }
                guard Self.mouseClickBlocker(el, pid: pid) == nil, (try? el.click()) != nil else { return nil }
            } else {
                _ = try? el.performAction(.showMenu)
            }
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                // The real on-screen menu wins: Chrome also lists a web-side AXMenu under the
                // control, but its items have no AXPress and bogus frames — keep waiting for
                // the on-screen one while the child menu's items can't be pressed.
                if let m = onScreen() { return m }
                if let m = menuChild(), items(of: m).first?.el.isActionSupported(AXAction.press.rawValue) != false { return m }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return menuChild()
        }
        guard let rootMenu = openMenu() else {
            return errorJSON("\(role) '\(label)' did not open a menu. Use click_element on it, then click the option.")
        }
        func fail(_ msg: String) -> String {
            // Close the menu so the app isn't left in a modal tracking loop.
            _ = try? rootMenu.performAction(.cancel)
            // Chrome's <select> popup ignores AXCancel on its menu; its items take it.
            if rootMenu.role() != nil, let first = items(of: rootMenu).first?.el { _ = try? first.performAction(.cancel) }
            // Still open (Chrome ignores both): Escape, only while that app is frontmost.
            Thread.sleep(forTimeInterval: 0.2)
            if Self.onScreenPopUpMenu(pid: pid) != nil || el.children(strict: true)?.contains(where: { $0.role() == "AXMenu" }) == true,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               let esc = try? Self.parseKeySequence("esc").first {
                try? Self.post(esc)
            }
            return errorJSON(msg)
        }
        let path = option.components(separatedBy: " > ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !path.isEmpty else { return fail("Option is empty") }
        var menu = rootMenu
        var picked: [String] = []
        for (i, part) in path.enumerated() {
            let list = items(of: menu)
            guard let pick = Self.bestMatch(list, part) else {
                let names = list.map(\.title).prefix(40).joined(separator: " | ")
                let where_ = picked.isEmpty ? "\(role) '\(label)'" : "submenu '\(picked.joined(separator: " > "))'"
                return fail("No option '\(part)' in \(where_). Options: \(names)")
            }
            picked.append(pick.title)
            if pick.el.isEnabled() == false {
                return fail("Option '\(picked.joined(separator: " > "))' is disabled")
            }
            if i < path.count - 1 {
                // Descend: the submenu is an AXMenu child of the item (open it if it isn't built yet).
                func sub() -> Element? { pick.el.children(strict: true)?.first { $0.role() == "AXMenu" } }
                if sub() == nil { _ = try? pick.el.performAction(.press) }
                let deadline = Date().addingTimeInterval(1.0)
                while sub() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                guard let s = sub() else { return fail("'\(pick.title)' has no submenu") }
                menu = s
                continue
            }
            if pick.el.isActionSupported(AXAction.press.rawValue) {
                do {
                    try pick.el.performAction(.press)
                } catch {
                    return fail("Could not press option '\(pick.title)': \(error.localizedDescription)")
                }
            } else {
                // Items without AXPress (Chrome's <select> popup): hit-tested mouse click.
                if let blocked = Self.mouseClickBlocker(pick.el, pid: pid) {
                    return fail("Option '\(pick.title)' has no AXPress and can't be clicked — \(blocked)")
                }
                guard (try? pick.el.click()) != nil else { return fail("Could not click option '\(pick.title)'") }
            }
        }

        let last = picked.last ?? ""
        // The control updates asynchronously — wait (≤1s) until it shows the pick.
        func shown() -> String { (el.value() as? String) ?? el.title() ?? "" }
        let deadline = Date().addingTimeInterval(1.0)
        while shown() != last, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let now = shown()
        // A web <select> always shows its selected option — if it doesn't, the pick didn't take.
        if isWeb, now.caseInsensitiveCompare(last) != .orderedSame {
            return errorJSON("Picked '\(last)' in \(role) '\(label)' but it still shows '\(now)'")
        }
        var result: [String: Any] = ["message": "Selected '\(picked.joined(separator: " > "))' in \(role) '\(label)'", "selected": last]
        if !now.isEmpty { result["value"] = now }
        return successJSON(result)
    }

    /// Radio group / segmented control / tab group: press the child button whose
    /// title or description matches `option` — AppleScript's
    /// `click radio button "X" of radio group 1` — and wait until it reads as selected.
    @MainActor
    private func pickChild(_ el: Element, role: String, label: String, option: String) -> String {
        var buttons: [(title: String, el: Element)] = []
        func collect(_ e: Element, _ depth: Int) {
            for c in e.children(strict: true) ?? [] {
                let r = c.role() ?? ""
                if r == "AXRadioButton" || r == "AXTab" || r == "AXButton" || r == "AXCheckBox" {
                    let t = [c.title(), c.descriptionText(), c.value() as? String].compactMap { $0 }.first { !$0.isEmpty }
                    if let t { buttons.append((t, c)) }
                } else if depth < 2 {
                    collect(c, depth + 1)
                }
            }
        }
        collect(el, 0)
        // A tab group also contains the selected tab's controls — use its AXTabs when it has them.
        if role == "AXTabGroup", let tabs: [AXUIElement] = el.attribute(Attribute<[AXUIElement]>("AXTabs")), !tabs.isEmpty {
            buttons = tabs.map(Element.init).compactMap { t in
                [t.title(), t.descriptionText()].compactMap { $0 }.first { !$0.isEmpty }.map { ($0, t) }
            }
        }
        guard let pick = Self.bestMatch(buttons, option) else {
            let names = buttons.map(\.title).prefix(40).joined(separator: " | ")
            return errorJSON("No option '\(option)' in \(role) '\(label)'. Options: \(names)")
        }
        func isOn() -> Bool {
            if let n = pick.el.value() as? NSNumber { return n.intValue == 1 }
            let sel: Bool? = pick.el.attribute(Attribute<Bool>("AXSelected"))
            return sel == true
        }
        if isOn() {
            return successJSON(["message": "'\(pick.title)' already selected in \(role) '\(label)'", "selected": pick.title, "changed": false])
        }
        if pick.el.isEnabled() == false {
            return errorJSON("Option '\(pick.title)' is disabled")
        }
        if (try? pick.el.performAction(.press)) == nil, (try? pick.el.click()) == nil {
            return errorJSON("Could not press '\(pick.title)'")
        }
        let deadline = Date().addingTimeInterval(1.5)
        while !isOn(), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard isOn() else {
            return errorJSON("Pressed '\(pick.title)' in \(role) '\(label)' but it does not read as selected")
        }
        return successJSON(["message": "Selected '\(pick.title)' in \(role) '\(label)'", "selected": pick.title, "changed": true])
    }
}

