import AXorcist
import Foundation

/// AppleScript-style element references — the System Events way of addressing UI:
/// `button 2 of toolbar 1 of window 1`, `text field "Name" of sheet 1 of window "Doc"`,
/// `checkbox 1 of group 3 of window 1`, `menu item "Copy" of menu 1 of menu bar item "Edit" of menu bar 1`.
/// Accepted anywhere a `title` is (find, click, type, read_text, select_option, …), so elements
/// with no title (icon buttons, unnamed fields) can be addressed exactly. find_element /
/// get_properties / get_focused_element / get_children return each element's `reference`,
/// so a found element can be acted on again without guessing.
extension AccessibilityService {
    /// AppleScript (System Events) class name → AX role. "UI element" matches any role.
    static let referenceClasses: [(name: String, role: String)] = [
        ("window", "AXWindow"), ("sheet", "AXSheet"), ("drawer", "AXDrawer"),
        ("button", "AXButton"), ("checkbox", "AXCheckBox"), ("radio button", "AXRadioButton"),
        ("radio group", "AXRadioGroup"), ("text field", "AXTextField"), ("text area", "AXTextArea"),
        ("static text", "AXStaticText"), ("pop up button", "AXPopUpButton"), ("menu button", "AXMenuButton"),
        ("combo box", "AXComboBox"), ("slider", "AXSlider"), ("group", "AXGroup"),
        ("scroll area", "AXScrollArea"), ("scroll bar", "AXScrollBar"), ("table", "AXTable"),
        ("outline", "AXOutline"), ("row", "AXRow"), ("column", "AXColumn"), ("cell", "AXCell"),
        ("toolbar", "AXToolbar"), ("tab group", "AXTabGroup"), ("splitter group", "AXSplitGroup"),
        ("splitter", "AXSplitter"), ("image", "AXImage"), ("list", "AXList"), ("browser", "AXBrowser"),
        ("menu bar item", "AXMenuBarItem"), ("menu bar", "AXMenuBar"), ("menu item", "AXMenuItem"),
        ("menu", "AXMenu"), ("incrementor", "AXIncrementor"), ("progress indicator", "AXProgressIndicator"),
        ("busy indicator", "AXBusyIndicator"), ("level indicator", "AXLevelIndicator"),
        ("value indicator", "AXValueIndicator"), ("color well", "AXColorWell"), ("date field", "AXDateField"),
        ("disclosure triangle", "AXDisclosureTriangle"), ("link", "AXLink"), ("heading", "AXHeading"),
        ("web area", "AXWebArea"), ("layout area", "AXLayoutArea"), ("relevance indicator", "AXRelevanceIndicator"),
        ("grow area", "AXGrowArea"), ("matte", "AXMatte"), ("ruler", "AXRuler"), ("system wide", "AXSystemWide"),
        ("UI element", "*"),
    ]

    struct ReferenceSpec {
        let role: String          // AX role, or "*" for any
        let index: Int?           // 1-based; negative counts from the end
        let name: String?
    }

    /// Parse `button 2 of toolbar 1 of window "Doc"` into specs, outermost first.
    /// Returns nil when the text isn't a reference (so it's searched as a plain title).
    static func parseReference(_ text: String) -> [ReferenceSpec]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Split on " of " outside quotes.
        var parts: [String] = []
        var cur = ""
        var inQuote = false
        let chars = Array(trimmed)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "“" || c == "”" { inQuote.toggle(); cur.append("\""); i += 1; continue }
            if !inQuote, c == " ", i + 4 <= chars.count, String(chars[i..<min(i + 4, chars.count)]).lowercased() == " of " {
                parts.append(cur); cur = ""; i += 4; continue
            }
            cur.append(c); i += 1
        }
        parts.append(cur)
        var specs: [ReferenceSpec] = []
        for part in parts {
            guard let spec = parseSpec(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            specs.append(spec)
        }
        // A bare "Save" or "window" is a title, not a reference: require an index or a name.
        if specs.count == 1, specs[0].index == nil, specs[0].name == nil { return nil }
        return Array(specs.reversed())
    }

    private static func parseSpec(_ s: String) -> ReferenceSpec? {
        var body = s
        if body.lowercased().hasPrefix("the ") { body = String(body.dropFirst(4)) }
        // Ordinals: "first button", "last row".
        var ordinal: Int?
        for (word, n) in [("first ", 1), ("second ", 2), ("third ", 3), ("last ", -1)] where body.lowercased().hasPrefix(word) {
            ordinal = n; body = String(body.dropFirst(word.count)); break
        }
        let lower = body.lowercased()
        var role: String?
        var rest = ""
        if body.hasPrefix("AX") {
            // Raw AX role: "AXWebArea 1", "AXLink \"Home\"".
            let end = body.firstIndex(of: " ") ?? body.endIndex
            role = String(body[..<end]); rest = String(body[end...])
        } else {
            // Longest class name first ("menu bar item" before "menu bar" before "menu").
            for entry in referenceClasses.sorted(by: { $0.name.count > $1.name.count }) {
                let n = entry.name.lowercased()
                if lower == n || lower.hasPrefix(n + " ") {
                    role = entry.role; rest = String(body.dropFirst(n.count)); break
                }
            }
        }
        guard let role else { return nil }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return ReferenceSpec(role: role, index: ordinal, name: nil) }
        guard ordinal == nil else { return nil }
        if rest.lowercased() == "last" { return ReferenceSpec(role: role, index: -1, name: nil) }
        if let n = Int(rest), n != 0 { return ReferenceSpec(role: role, index: n, name: nil) }
        if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") {
            return ReferenceSpec(role: role, index: nil, name: String(rest.dropFirst().dropLast()))
        }
        return nil
    }

    @MainActor
    static func referenceName(of el: Element) -> String? {
        if let t = el.title(), !t.isEmpty { return t }
        if let d = el.descriptionText(), !d.isEmpty { return d }
        return nil
    }

    private static func normalizedName(_ s: String) -> String {
        s.replacingOccurrences(of: "…", with: "...").lowercased().trimmingCharacters(in: .whitespaces)
    }

    @MainActor
    private static func referenceChildren(of el: Element, role: String) -> [Element] {
        if el.role() == "AXApplication" {
            if role == "AXMenuBar" { return el.menuBar().map { [$0] } ?? [] }
            if role == "AXWindow" || role == "AXSheet" { return el.windows() ?? [] }
        }
        return el.children(strict: true) ?? []
    }

    @MainActor
    private static func pick(_ spec: ReferenceSpec, from candidates: [Element]) -> Element? {
        let matching = candidates.filter { spec.role == "*" || $0.role() == spec.role }
        if let name = spec.name {
            let want = normalizedName(name)
            let named = matching.first { el in
                [el.title(), el.descriptionText(), el.identifier()].contains { $0.map(normalizedName) == want }
            } ?? matching.first { ($0.value() as? String).map(normalizedName) == want }
            // AppleScript names a menu after its menu bar item / menu item ("menu \"File\""),
            // but AXMenu has no title of its own.
            if named == nil, spec.role == "AXMenu" { return matching.first }
            return named
        }
        guard !matching.isEmpty else { return nil }
        let idx = spec.index ?? 1
        if idx > 0 { return idx <= matching.count ? matching[idx - 1] : nil }
        return -idx <= matching.count ? matching[matching.count + idx] : nil
    }

    /// Resolve specs (outermost first) under the app element. Each level is looked up among
    /// direct children like AppleScript; if that fails, among descendants (breadth-first), so a
    /// reference that skips an unnamed group ("button \"OK\" of window 1") still resolves.
    @MainActor
    func resolveReference(_ specs: [ReferenceSpec], in app: Element) -> Element? {
        var current = app
        for (level, spec) in specs.enumerated() {
            if let direct = Self.pick(spec, from: Self.referenceChildren(of: current, role: spec.role)) {
                current = direct
                continue
            }
            // Implicit front window: "button 1" / "text field \"Name\"" with no window.
            if level == 0, current.role() == "AXApplication", spec.role != "AXWindow", spec.role != "AXMenuBar",
               let win = current.focusedWindow() ?? current.windows()?.first,
               let found = resolveReference(specs, in: win) {
                return found
            }
            var queue = Self.referenceChildren(of: current, role: spec.role)
            var all: [Element] = []
            var visited = 0
            while !queue.isEmpty, visited < 3000 {
                let el = queue.removeFirst()
                visited += 1
                all.append(el)
                queue.append(contentsOf: el.children(strict: true) ?? [])
            }
            guard let deep = Self.pick(spec, from: all) else { return nil }
            current = deep
        }
        return current
    }

    /// If `title` is an AppleScript-style reference, resolve it in the target app (or front app).
    @MainActor
    func findByReference(_ title: String?, appBundleId: String?) -> Element? {
        guard let title, let specs = Self.parseReference(title) else { return nil }
        let app: Element?
        if let bundleId = lookupBundleId(appBundleId),
           let running = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first {
            app = Element.application(for: running)
        } else if let front = RunningApplicationHelper.frontmostApplication {
            app = Element.application(for: front)
        } else {
            app = nil
        }
        guard let app else { return nil }
        return resolveReference(specs, in: app)
    }

    // MARK: - Building references

    static func className(forRole role: String) -> String {
        referenceClasses.first { $0.role == role }?.name ?? role
    }

    /// One reference level for `el` among `siblings`: `button "OK"` when the name is unique
    /// among same-role siblings, else `button 3`.
    @MainActor
    static func referenceSpec(for el: Element, among siblings: [Element]) -> String {
        let role = el.role() ?? "AXUnknown"
        let cls = className(forRole: role)
        let same = siblings.filter { $0.role() == role }
        if let name = referenceName(of: el), !name.contains("\""), name.count <= 60,
           same.filter({ referenceName(of: $0) == name }).count == 1 {
            return "\(cls) \"\(name)\""
        }
        let idx = (same.firstIndex(of: el) ?? 0) + 1
        return "\(cls) \(idx)"
    }

    /// Full AppleScript-style reference of an element, e.g. `button 2 of group 1 of window "Doc"`.
    @MainActor
    func reference(of el: Element) -> String? {
        var parts: [String] = []
        var cur: Element? = el
        for _ in 0..<40 {
            guard let c = cur, let role = c.role() else { return nil }
            if role == "AXApplication" { break }
            let parent = c.parent()
            // Top level (window, sheet, menu bar): index among the app's own list, like AppleScript.
            if parent == nil || parent?.role() == "AXApplication" {
                let app = c.pid().flatMap { Element.application(for: $0) }
                let siblings: [Element]
                switch role {
                case "AXWindow", "AXSheet": siblings = app?.windows() ?? [c]
                case "AXMenuBar": siblings = [c]
                default: siblings = parent?.children(strict: true) ?? [c]
                }
                parts.append(Self.referenceSpec(for: c, among: siblings))
                break
            }
            parts.append(Self.referenceSpec(for: c, among: parent?.children(strict: true) ?? [c]))
            cur = parent
        }
        return parts.isEmpty ? nil : parts.joined(separator: " of ")
    }

    /// elementProperties plus the element's `reference`.
    @MainActor
    func propertiesWithReference(_ el: Element) -> [String: Any] {
        var props = elementProperties(el)
        if let ref = reference(of: el) { props["reference"] = ref }
        return props
    }
}
