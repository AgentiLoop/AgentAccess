import AXorcist
import AppKit
import Foundation

/// set_properties helpers — AppleScript `set <property> of <element> to <value>`:
/// AppleScript property names, value coercion to the attribute's real type,
/// read-back of what the app actually applied, and a press fallback for toggles.
extension AccessibilityService {
    enum AXValueKind { case bool, number, string, point, size, range, rect, unknown }

    /// System Events property names → AX attribute names.
    static let appleScriptPropertyNames: [String: String] = [
        "value": "AXValue", "position": "AXPosition", "size": "AXSize", "focused": "AXFocused",
        "selected": "AXSelected", "selected text": "AXSelectedText", "selected text range": "AXSelectedTextRange",
        "visible character range": "AXVisibleCharacterRange", "expanded": "AXExpanded", "disclosing": "AXDisclosing",
        "minimized": "AXMinimized", "main": "AXMain", "frontmost": "AXFrontmost", "hidden": "AXHidden",
        "title": "AXTitle", "full screen": "AXFullScreen", "enabled": "AXEnabled",
    ]

    /// "value" / "selected text range" / "selectedTextRange" / "AXValue" → AX attribute name.
    static func axAttributeName(_ key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespaces)
        if k.hasPrefix("AX") { return k }
        let lower = k.lowercased().replacingOccurrences(of: "_", with: " ")
        if let mapped = appleScriptPropertyNames[lower] { return mapped }
        let words = lower.split(separator: " ")
        if words.count > 1 { return "AX" + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() }
        return "AX" + k.prefix(1).uppercased() + k.dropFirst()
    }

    static func valueKind(attribute: String, current: CFTypeRef?) -> AXValueKind {
        if let c = current {
            let t = CFGetTypeID(c)
            if t == CFBooleanGetTypeID() { return .bool }
            if t == CFNumberGetTypeID() { return .number }
            if t == CFStringGetTypeID() { return .string }
            if t == AXValueGetTypeID() {
                switch AXValueGetType(c as! AXValue) {
                case .cgPoint: return .point
                case .cgSize: return .size
                case .cfRange: return .range
                case .cgRect: return .rect
                default: return .unknown
                }
            }
        }
        switch attribute {
        case "AXPosition": return .point
        case "AXSize": return .size
        case "AXSelectedTextRange", "AXVisibleCharacterRange": return .range
        case "AXFocused", "AXSelected", "AXExpanded", "AXDisclosing", "AXMinimized", "AXMain",
             "AXFrontmost", "AXHidden", "AXFullScreen", "AXEnabled": return .bool
        default: return .unknown
        }
    }

    /// Number from a JSON number, numeric string, or AppleScript-ish boolean word.
    static func coercedNumber(_ v: Any) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let d = Double(t) { return d }
        switch t {
        case "true", "yes", "on", "checked": return 1
        case "false", "no", "off", "unchecked": return 0
        default: return nil
        }
    }

    /// N numbers from {"x":1,"y":2}, [1, 2], or "{1, 2}" / "1,2" / "1 2".
    static func coercedNumbers(_ v: Any, keys: [String]) -> [Double]? {
        var vals: [Double] = []
        if let d = v as? [String: Any] {
            vals = keys.compactMap { k in d[k].flatMap { coercedNumber($0) } }
        } else if let a = v as? [Any] {
            vals = a.compactMap { coercedNumber($0) }
        } else if let s = v as? String, let re = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?") {
            vals = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Range($0.range, in: s).flatMap { Double(s[$0]) }
            }
        }
        return vals.count == keys.count ? vals : nil
    }

    static func coerceAXValue(_ v: Any, to kind: AXValueKind) -> CFTypeRef? {
        switch kind {
        case .bool:
            guard let d = coercedNumber(v) else { return nil }
            return (d != 0 ? kCFBooleanTrue : kCFBooleanFalse)
        case .number:
            guard let d = coercedNumber(v) else { return nil }
            return d == d.rounded() && abs(d) < 1e15 ? NSNumber(value: Int(d)) : NSNumber(value: d)
        case .string:
            if let s = v as? String { return s as CFString }
            if let n = v as? NSNumber { return n.stringValue as CFString }
            return String(describing: v) as CFString
        case .point:
            guard let n = coercedNumbers(v, keys: ["x", "y"]) else { return nil }
            var p = CGPoint(x: n[0], y: n[1])
            return AXValueCreate(.cgPoint, &p)
        case .size:
            guard let n = coercedNumbers(v, keys: ["width", "height"]) else { return nil }
            var s = CGSize(width: n[0], height: n[1])
            return AXValueCreate(.cgSize, &s)
        case .range:
            guard let n = coercedNumbers(v, keys: ["location", "length"]) else { return nil }
            var r = CFRange(location: Int(n[0]), length: Int(n[1]))
            return AXValueCreate(.cfRange, &r)
        case .rect:
            guard let n = coercedNumbers(v, keys: ["x", "y", "width", "height"]) else { return nil }
            var r = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
            return AXValueCreate(.cgRect, &r)
        case .unknown:
            if let s = v as? String { return s as CFString }
            if let n = v as? NSNumber { return n }
            return nil
        }
    }

    /// JSON-friendly form of an attribute value for the result.
    @MainActor
    static func describeAXValue(_ v: CFTypeRef?) -> Any {
        guard let v else { return NSNull() }
        let t = CFGetTypeID(v)
        if t == CFBooleanGetTypeID() { return (v as! NSNumber).boolValue }
        if t == CFNumberGetTypeID() { return v as! NSNumber }
        if t == CFStringGetTypeID() {
            let s = v as! String
            return s.count > 500 ? String(s.prefix(500)) + "…" : s
        }
        if t == AXValueGetTypeID() {
            let ax = v as! AXValue
            switch AXValueGetType(ax) {
            case .cgPoint:
                var p = CGPoint.zero; AXValueGetValue(ax, .cgPoint, &p)
                return ["x": p.x, "y": p.y]
            case .cgSize:
                var s = CGSize.zero; AXValueGetValue(ax, .cgSize, &s)
                return ["width": s.width, "height": s.height]
            case .cfRange:
                var r = CFRange(); AXValueGetValue(ax, .cfRange, &r)
                return ["location": r.location, "length": r.length]
            case .cgRect:
                var r = CGRect.zero; AXValueGetValue(ax, .cgRect, &r)
                return ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
            default: return String(describing: v)
            }
        }
        if t == AXUIElementGetTypeID() { return Element(v as! AXUIElement).role() ?? "element" }
        return String(describing: v)
    }

    /// Sets one attribute like AppleScript `set`: coerces, sets, reads back.
    /// Toggles whose AXValue can't be set are pressed instead (AppleScript `click checkbox`).
    @MainActor
    func setAXProperty(_ element: Element, key: String, value: Any) -> [String: Any] {
        let attr = Self.axAttributeName(key)
        let before = element.rawAttributeValue(named: attr)
        let kind = Self.valueKind(attribute: attr, current: before)
        guard let target = Self.coerceAXValue(value, to: kind) else {
            return ["attribute": attr, "status": "failed",
                    "error": "Can't convert \(value) to the \(kind) value \(attr) expects"]
        }
        var result: [String: Any] = ["attribute": attr, "before": Self.describeAXValue(before)]
        let settable = element.isAttributeSettable(named: attr)
        let role = element.role() ?? ""
        var applied: Bool

        // Pop-up / menu button: its AXValue can't be written (AppleScript can't `set value` of one
        // either — it clicks `menu item "X" of menu 1 of pop up button 1`), so pick the menu item.
        if attr == "AXValue", ["AXPopUpButton", "AXMenuButton"].contains(role) {
            let want = (value as? String) ?? "\(value)"
            if let have = before.map({ Self.describeAXValue($0) }) as? String,
               have.caseInsensitiveCompare(want) == .orderedSame {
                result["status"] = "unchanged"
                result["after"] = have
                return result
            }
            let label = [element.title(), element.descriptionText()].compactMap { $0 }.first { !$0.isEmpty } ?? role
            let picked = pickFromMenu(element, role: role, label: label, option: want)
            let r = (try? JSONSerialization.jsonObject(with: Data(picked.utf8))) as? [String: Any] ?? [:]
            result["after"] = Self.describeAXValue(element.rawAttributeValue(named: attr))
            result["via"] = "menu item"
            if r["success"] as? Bool == true {
                result["status"] = "set"
                if let sel = r["selected"] { result["selected"] = sel }
            } else {
                result["status"] = "failed"
                result["error"] = r["error"] as? String ?? picked
            }
            return result
        }

        // Slider / stepper: set AXValue, and when the app ignores or rejects it, step there with
        // AXIncrement / AXDecrement (what a user does with arrow keys).
        if attr == "AXValue", ["AXSlider", "AXIncrementor"].contains(role), let want = Self.coercedNumber(value) {
            func current() -> Double? { element.rawAttributeValue(named: attr).flatMap { Self.coercedNumber($0 as Any) } }
            let have = current()
            if let have, abs(have - want) < 1e-9 {
                result["status"] = "unchanged"
                result["after"] = Self.describeAXValue(before)
                return result
            }
            if settable, element.setValue(target, forAttribute: attr) {
                let deadline = Date().addingTimeInterval(0.5)
                while Date() < deadline, current().map({ abs($0 - want) >= 1e-9 }) ?? true {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            var now = current()
            if let n = now, n != have, abs(n - want) < 1e-9 || !element.isActionSupported(AXAction.increment.rawValue) {
                result["after"] = Self.describeAXValue(element.rawAttributeValue(named: attr))
                result["status"] = abs(n - want) < 1e-9 ? "set" : "adjusted"
                if abs(n - want) >= 1e-9 { result["note"] = "The control snapped to \(n)" }
                return result
            }
            var steps = 0
            if var cur = now {
                let up = want > cur
                while steps < 500, abs(cur - want) >= 1e-9 {
                    guard (try? element.performAction(up ? .increment : .decrement)) != nil else { break }
                    steps += 1
                    var next = current()
                    let deadline = Date().addingTimeInterval(0.3)
                    while next == cur, Date() < deadline {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                        next = current()
                    }
                    guard let n = next, n != cur else { break }
                    if up ? n > want : n < want {
                        // Overshot: step back when the previous value was closer.
                        if abs(cur - want) < abs(n - want), (try? element.performAction(up ? .decrement : .increment)) != nil {
                            steps += 1
                            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                            cur = current() ?? cur
                        } else { cur = n }
                        break
                    }
                    cur = n
                }
                now = current()
            }
            result["after"] = Self.describeAXValue(element.rawAttributeValue(named: attr))
            if let n = now, abs(n - want) < 1e-9 {
                result["status"] = "set"
            } else if let n = now, n != have {
                result["status"] = "adjusted"
                result["note"] = "Nearest step to \(want) is \(n)"
            } else {
                result["status"] = settable ? "no effect" : "not settable"
                result["error"] = "\(role) didn't move to \(want) (AXValue set and AXIncrement/AXDecrement both ignored)"
            }
            if steps > 0 { result["via"] = "AXIncrement/AXDecrement ×\(steps)" }
            return result
        }

        // Checkbox / switch / radio button: press it when the state differs (AppleScript `click checkbox`).
        // Their AXValue is often read-only — or reported settable while writes are silently ignored
        // (TextEdit Settings checkboxes), so pressing is the only reliable route.
        if attr == "AXValue", ["AXCheckBox", "AXRadioButton", "AXSwitch"].contains(role),
           let want = Self.coercedNumber(value), let have = before.flatMap({ Self.coercedNumber($0 as Any) })
        {
            if (want != 0) == (have != 0) {
                result["status"] = "unchanged"
                result["after"] = Self.describeAXValue(before)
                result["note"] = "already \(want != 0 ? "on" : "off")"
                return result
            }
            if role == "AXRadioButton" && want == 0 {
                result["status"] = "failed"
                result["error"] = "A radio button turns off by selecting another one in its group"
                return result
            }
            applied = (try? element.performAction(.press)) != nil
            if applied { result["via"] = "AXPress" } else { applied = element.setValue(target, forAttribute: attr) }
        } else {
            applied = element.setValue(target, forAttribute: attr)
        }

        guard applied else {
            result["status"] = settable ? "failed" : "not settable"
            result["error"] = settable
                ? "The app rejected \(attr) = \(Self.describeAXValue(target))"
                : "\(attr) is read-only on this \(role.isEmpty ? "element" : role)"
                    + (attr == "AXValue" ? " — use type_into_element for text, select_option for pop-ups/sliders/checkboxes" : "")
            return result
        }

        // Read back — the app may clamp (window position/size), normalize, or ignore the value.
        var after = element.rawAttributeValue(named: attr)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, !(after.map { CFEqual($0, target) } ?? false) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            after = element.rawAttributeValue(named: attr)
        }
        result["after"] = Self.describeAXValue(after)
        if let after, CFEqual(after, target) {
            result["status"] = before.map { CFEqual($0, target) } ?? false ? "unchanged" : "set"
        } else if let after, let before, CFEqual(after, before) {
            result["status"] = "no effect"
            result["error"] = "The app accepted the value but \(attr) didn't change"
        } else if after == nil && before == nil && !settable {
            result["status"] = "no effect"
            result["error"] = "This \(role.isEmpty ? "element" : role) has no settable \(attr)"
        } else if after == nil {
            result["status"] = "set"
            result["note"] = "\(attr) can't be read back"
        } else {
            result["status"] = "adjusted"
            result["note"] = "The app applied a different value than requested"
        }
        return result
    }
}
