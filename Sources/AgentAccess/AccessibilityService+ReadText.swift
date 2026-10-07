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
            let window = appElement.focusedWindow() ?? appElement.mainWindow() ?? appElement.windows()?.first
            if let window {
                wakeAccessibilityTree(appElement) { !Self.hasHollowContent(window) }
            }
            root = window ?? appElement
        }

        var lines: [String] = []
        var chars = 0
        var visited = 0
        var truncated = false
        var emptyWebAreas = 0

        // One huge text area (Agent!'s activity log, a long document) used to
        // eat the whole budget and hide every control after it — clip it.
        let perLine = max(1500, maxChars / 5)
        func emit(_ rawLine: String, clip: Bool = true) {
            guard !truncated else { return }
            var line = rawLine
            if clip, line.count > perLine {
                line = String(line.prefix(perLine)) + "… [+\(line.count - perLine) chars; read_text with this element's role/title for all of it]"
            }
            if lines.last == line { return }
            if chars + line.count > maxChars {
                truncated = true
                return
            }
            lines.append(line)
            chars += line.count + 1
        }

        func label(_ r: String) -> String { r.hasPrefix("AX") ? String(r.dropFirst(2)) : r }

        func walk(_ el: Element, depth: Int, inWeb: Bool) {
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

            var own = Self.ownText(el, role: r)
            // Web group labels can span lines ("Small\nStandard\nLarge").
            if inWeb { own = own.map { Self.joinInline([$0]) }.flatMap { $0.isEmpty ? nil : $0 } }
            if let own { emit("\(label(r)): \(own)", clip: depth > 0) }
            // strict: AXChildren only, in reading order — the alternative
            // attributes (AXRows, AXVisibleChildren, …) would read rows twice.
            let children = el.children(strict: true) ?? []
            let web = inWeb || r == "AXWebArea"
            if r == "AXWebArea" && children.isEmpty { emptyWebAreas += 1 }
            guard web else {
                for child in children { walk(child, depth: depth + 1, inWeb: false) }
                return
            }

            // Web content: a paragraph is a run of sibling text nodes and links —
            // join them into one line instead of one line per fragment, and drop
            // the StaticText that only repeats its link/heading/button's label.
            var run: [String] = []
            var runIsSingleLink = false
            func flush() {
                defer { run = []; runIsSingleLink = false }
                let text = Self.joinInline(run)
                guard !text.isEmpty, text != own else { return }
                // A visible label right after its control ("RadioButton: Small [off]" + "Small").
                if let last = lines.last, let colon = last.range(of: ": ") {
                    let lastText = last[colon.upperBound...]
                    if lastText == text || lastText.hasPrefix(text + " [") { return }
                }
                let kind = runIsSingleLink && run.count == 1 ? "Link" : (own == nil && r == "AXHeading" ? "Heading" : "Text")
                emit("\(kind): \(text)")
            }
            let roles = children.map { $0.role() ?? "" }
            func isTextNode(_ i: Int) -> Bool {
                i >= 0 && i < roles.count && (roles[i] == "AXStaticText" || roles[i] == "AXLink")
            }
            for (i, child) in children.enumerated() {
                let cr = roles[i]
                // <b>/<i>/<code>/<sup> spans are untitled AXGroups sitting among text nodes.
                let inlineGroup = cr == "AXGroup"
                    && (isTextNode(i - 1) || isTextNode(i + 1) || (child.subrole() ?? "").hasSuffix("StyleGroup"))
                    && Self.isInlineSpan(child)
                if cr == "AXStaticText" || cr == "AXLink" || inlineGroup {
                    if child.isHidden() == true { continue }
                    visited += 1
                    let t = Self.inlineText(child, role: cr)
                    if t.isEmpty { continue }
                    if run.isEmpty { runIsSingleLink = cr == "AXLink" }
                    run.append(t)
                } else {
                    flush()
                    walk(child, depth: depth + 1, inWeb: true)
                }
            }
            flush()
        }

        walk(root, depth: 0, inWeb: false)
        // WebKit/Chromium build a page's accessibility tree lazily: the first
        // query can find an empty web area. Give it a moment and read again.
        var retries = 0
        while emptyWebAreas > 0 && retries < 6 && !truncated {
            retries += 1
            Thread.sleep(forTimeInterval: 0.4)
            lines = []; chars = 0; visited = 0; emptyWebAreas = 0
            walk(root, depth: 0, inWeb: false)
        }


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

    /// Text of an inline web node: a text run's value, or a link's visible text
    /// (its StaticText descendants, falling back to its label for image links).
    @MainActor
    static func inlineText(_ el: Element, role: String) -> String {
        if role == "AXStaticText" {
            return (el.value() as? String) ?? el.title() ?? ""
        }
        var parts: [String] = []
        func collect(_ e: Element, depth: Int) {
            guard depth <= 6, parts.count < 60 else { return }
            for c in e.children(strict: true) ?? [] {
                if c.role() == "AXStaticText", let v = (c.value() as? String) ?? c.title() {
                    parts.append(v)
                } else {
                    collect(c, depth: depth + 1)
                }
            }
        }
        collect(el, depth: 0)
        let text = joinInline(parts)
        if !text.isEmpty { return text }
        return [el.title(), el.descriptionText()].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    /// An untitled group holding nothing but text runs, links and more such
    /// groups — a styled inline span rather than a block.
    @MainActor
    static func isInlineSpan(_ el: Element) -> Bool {
        if [el.title(), el.descriptionText()].contains(where: { !($0 ?? "").isEmpty }) { return false }
        var nodes = 0
        func ok(_ e: Element, depth: Int) -> Bool {
            guard depth <= 4 else { return false }
            for c in e.children(strict: true) ?? [] {
                nodes += 1
                guard nodes <= 30 else { return false }
                switch c.role() ?? "" {
                case "AXStaticText": continue
                case "AXLink", "AXGroup": if !ok(c, depth: depth + 1) { return false }
                default: return false
                }
            }
            return true
        }
        return ok(el, depth: 0)
    }

    /// Join web text fragments the way the page renders them: fragments carry
    /// their own spacing, except adjacent words split across nodes.
    static func joinInline(_ parts: [String]) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if let last = out.last, let first = p.first,
               (last.isLetter || last.isNumber), (first.isLetter || first.isNumber) {
                out += " "
            }
            out += p
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
