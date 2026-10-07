import AgentAudit
import AXorcist
import Foundation
import AppKit

// MARK: - Read Text

extension AccessibilityService {

    /// Read every visible piece of text in an app's window (or a matched element)
    /// in reading order — the accessibility equivalent of AppleScript's
    /// `get text of document 1` / `get value of every static text of window 1` /
    /// `get name of every row of table 1`, but working in any app, scriptable or not.
    /// Table/outline rows come back as one line with cells joined by " | ";
    /// checkboxes and radio buttons carry their on/off state.
    @MainActor
    public func readText(role: String?, title: String?, value: String?, appBundleId: String?, maxDepth: Int = 40, maxChars: Int = 20000) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "readText(role: \(role ?? "nil"), title: \(title ?? "nil"), app: \(appBundleId ?? "frontmost"))")

        let root: Element
        if role != nil || title != nil || value != nil {
            guard let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) else {
                return errorJSON("Element not found")
            }
            root = found
        } else {
            let runningApp = appBundleId.flatMap { RunningApplicationHelper.applications(withBundleIdentifier: $0).first }
                ?? RunningApplicationHelper.frontmostApplication
            guard let app = runningApp else {
                return errorJSON("App not running: \(appBundleId ?? "frontmost")")
            }
            guard let appElement = Element.application(for: app) else {
                return errorJSON("\(app.localizedName ?? appBundleId ?? "App") is running but not answering accessibility queries (busy or hung)")
            }
            root = appElement.focusedWindow() ?? appElement.mainWindow() ?? appElement.windows()?.first ?? appElement
        }

        var lines: [String] = []
        var chars = 0
        var visited = 0
        var truncated = false

        func emit(_ line: String) {
            guard !truncated else { return }
            if lines.last == line { return }
            if chars + line.count > maxChars {
                truncated = true
                return
            }
            lines.append(line)
            chars += line.count + 1
        }

        func walk(_ el: Element, depth: Int) {
            guard !truncated, depth <= maxDepth, visited < 8000 else {
                if visited >= 8000 { truncated = true }
                return
            }
            visited += 1
            if el.isHidden() == true { return }
            let r = el.role() ?? ""
            // Columns repeat every cell already read through the rows.
            if r == "AXMenuBar" || r == "AXScrollBar" || r == "AXColumn" { return }

            if r == "AXRow" {
                let cells = Self.rowCellTexts(el)
                if !cells.isEmpty {
                    let selected = (el.attribute(Attribute<Bool>("AXSelected")) ?? false) ? " [selected]" : ""
                    emit("Row\(selected): " + cells.joined(separator: " | "))
                }
                return
            }

            if let text = Self.ownText(el, role: r) {
                emit("\(r.hasPrefix("AX") ? String(r.dropFirst(2)) : r): \(text)")
            }
            // strict: AXChildren only, in reading order — the alternative
            // attributes (AXRows, AXVisibleChildren, …) would read rows twice.
            for child in el.children(strict: true) ?? [] {
                walk(child, depth: depth + 1)
            }
        }

        walk(root, depth: 0)

        var result: [String: Any] = [
            "root": [root.role() ?? "", root.title() ?? ""].filter { !$0.isEmpty }.joined(separator: " "),
            "lines": lines.count,
            "text": lines.joined(separator: "\n"),
        ]
        if truncated { result["truncated"] = true }
        if lines.isEmpty {
            return errorJSON("No text found in \(result["root"] as? String ?? "element")")
        }
        return successJSON(result)
    }

    /// Text an element shows by itself (not counting children), with state for toggles.
    @MainActor
    static func ownText(_ el: Element, role: String) -> String? {
        let title = el.title().flatMap { $0.isEmpty ? nil : $0 }
        let desc = el.descriptionText().flatMap { $0.isEmpty ? nil : $0 }
        let stringValue = (el.value() as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch role {
        case "AXStaticText", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXHeading":
            return stringValue ?? title ?? (role == "AXHeading" ? desc : nil)
        case "AXCheckBox", "AXRadioButton", "AXSwitch":
            guard let label = title ?? desc else { return nil }
            let on = (el.value() as? NSNumber)?.intValue ?? 0
            return "\(label) [\(on == 1 ? "on" : on == 2 ? "mixed" : "off")]"
        case "AXPopUpButton", "AXMenuButton":
            let label = title ?? desc
            if let label, let v = stringValue, label != v { return "\(label): \(v)" }
            return stringValue ?? label
        case "AXSlider", "AXProgressIndicator", "AXValueIndicator", "AXLevelIndicator":
            let n = (el.value() as? NSNumber).map { "\($0)" } ?? stringValue
            guard let n else { return title ?? desc }
            return "\(title ?? desc ?? "value") = \(n)"
        case "AXButton", "AXLink", "AXTab", "AXMenuItem", "AXDisclosureTriangle", "AXImage", "AXCell":
            return title ?? desc ?? stringValue
        default:
            return title ?? stringValue
        }
    }

    /// Texts of a table/outline row's cells, in column order.
    @MainActor
    static func rowCellTexts(_ row: Element) -> [String] {
        var out: [String] = []
        func collect(_ el: Element, depth: Int) {
            guard depth <= 6, out.count < 40 else { return }
            let r = el.role() ?? ""
            if r != "AXRow", r != "AXCell", r != "AXGroup", let text = ownText(el, role: r) {
                if out.last != text { out.append(text) }
                return
            }
            for child in el.children(strict: true) ?? [] { collect(child, depth: depth + 1) }
        }
        for child in row.children(strict: true) ?? [] { collect(child, depth: 0) }
        return out
    }
}
