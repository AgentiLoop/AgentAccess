import AgentAudit
import AXorcist
import AppKit
import Carbon.HIToolbox
import Foundation

extension AccessibilityService {

    // MARK: - Press Key

    /// Press keys / shortcuts in an app — the AX equivalent of System Events
    /// `keystroke "s" using {command down}` / `key code 125`.
    /// `keys` is a space-separated sequence of combos: "cmd+s", "cmd+shift+n",
    /// "return", "down*3", "cmd+,", "⌘⇧T", "esc tab tab space".
    /// Optional `text` is typed literally (at the focus, or into role/title) before the keys.
    /// The target app is brought forward and must be frontmost before anything is
    /// sent — keystrokes never leak into another app. The result reports the
    /// focused window/element before and after so the caller can see the effect.
    @MainActor
    public func pressKey(keys: String, text: String?, role: String?, title: String?, appBundleId: String?) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "pressKey(keys: \(keys), text: \(text?.count ?? 0) chars, role: \(role ?? "nil"), title: \(title ?? "nil"), app: \(appBundleId ?? "frontmost"))")

        let combos: [KeyCombo]
        do { combos = try Self.parseKeySequence(keys) } catch {
            return errorJSON("\(error)")
        }
        let literal = text ?? ""
        if combos.isEmpty && literal.isEmpty {
            return errorJSON("press_key needs keys (e.g. \"cmd+s\", \"return\", \"down*3\", \"cmd+shift+n\") or text to type.")
        }

        // Target app: explicit, or whatever is frontmost.
        let target: NSRunningApplication
        if let bid = appBundleId {
            guard let app = RunningApplicationHelper.applications(withBundleIdentifier: bid).first else {
                return errorJSON("App not running: \(bid)")
            }
            target = app
        } else if let front = NSWorkspace.shared.frontmostApplication {
            target = front
        } else {
            return errorJSON("No frontmost app to send keys to.")
        }
        let pid = target.processIdentifier
        let appName = target.localizedName ?? target.bundleIdentifier ?? "pid \(pid)"

        // Keystrokes go to the frontmost app — make sure that is the target.
        if !target.isActive {
            if let appEl = Element.application(for: pid) { _ = appEl.activate() }
            target.activate()
            let start = Date()
            while !target.isActive, Date().timeIntervalSince(start) < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
            return errorJSON("Could not bring \(appName) to the front (\(front) is frontmost) — no keys were sent, so nothing went to the wrong app.")
        }

        // Optional element to focus first (role/title), like clicking into a field.
        var focusedTarget: Element?
        if role != nil || title != nil {
            guard let el = findAXElement(role: role, title: title, value: nil, appBundleId: target.bundleIdentifier) else {
                return errorJSON("Element not found to focus before pressing keys (role=\(role ?? "any"), title=\(title ?? "any")) in \(appName). No keys were sent.")
            }
            if el.isFocused() != true, !el.setValue(true, forAttribute: "AXFocused") || el.isFocused() == false {
                try? el.click()
            }
            Thread.sleep(forTimeInterval: 0.15)
            focusedTarget = el
        }

        let before = Self.focusSnapshot(pid: pid)

        do {
            if !literal.isEmpty {
                try Element.typeText(literal)
                Thread.sleep(forTimeInterval: 0.05)
                // Typing into a named field: check it landed before pressing keys
                // (a just-launched app can drop the first keystrokes). Retry once via click.
                if let el = focusedTarget, el.role() != "AXSecureTextField", el.subrole() != "AXSecureTextField" {
                    func landed() -> Bool {
                        let start = Date()
                        repeat {
                            if Self.normalized(Self.currentText(el)).contains(Self.normalized(literal)) { return true }
                            Thread.sleep(forTimeInterval: 0.1)
                        } while Date().timeIntervalSince(start) < 0.6
                        return false
                    }
                    if !landed() {
                        try? el.click()
                        Thread.sleep(forTimeInterval: 0.2)
                        try Element.typeText(literal)
                        if !landed() {
                            return errorJSON("Typed \(literal.count) characters but \(el.role() ?? "the field") now contains \"\((Self.currentText(el) ?? "").prefix(200))\" — the keys (\(keys)) were NOT pressed. Retry, or use type_into_element.")
                        }
                    }
                }
            }
            for combo in combos {
                for _ in 0..<combo.repeatCount {
                    try Self.post(combo)
                    Thread.sleep(forTimeInterval: 0.03)
                }
            }
        } catch {
            return errorJSON("Key events failed: \(error)")
        }

        // Give the app up to 1s to react (menus, sheets, focus moves).
        var after = before
        let reactStart = Date()
        repeat {
            Thread.sleep(forTimeInterval: 0.1)
            after = Self.focusSnapshot(pid: pid)
        } while after == before && Date().timeIntervalSince(reactStart) < 1.0

        let pressed = combos.map(\.description).joined(separator: " ")
        var info: [String: Any] = [
            "app": appName,
            "keys": combos.map(\.description),
            "message": [literal.isEmpty ? nil : "Typed \(literal.count) characters",
                        combos.isEmpty ? nil : "Pressed \(pressed)"].compactMap { $0 }.joined(separator: ", then "),
        ]
        if let el = focusedTarget { info["focused_first"] = elementProperties(el) }
        info["before"] = before.dictionary
        info["after"] = after.dictionary
        var changes: [String] = []
        if before.frontApp != after.frontApp { changes.append("frontmost app → \(after.frontApp)") }
        if before.window != after.window { changes.append("window → \"\(after.window)\"") }
        if before.windowCount != after.windowCount { changes.append("windows \(before.windowCount) → \(after.windowCount)") }
        if before.sheetCount != after.sheetCount { changes.append("sheets \(before.sheetCount) → \(after.sheetCount)") }
        if before.focus != after.focus { changes.append("focus → \(after.focus)") }
        if before.value != after.value { changes.append("focused value changed") }
        info["changed"] = changes.isEmpty ? "nothing visible changed (the key may still have worked, e.g. a command with no UI)" : changes.joined(separator: "; ")
        return successJSON(info)
    }

    // MARK: - Snapshot

    struct FocusSnapshot: Equatable {
        var frontApp = ""
        var window = ""
        var windowCount = 0
        var sheetCount = 0
        var focus = ""
        var value = ""
        var dictionary: [String: Any] {
            ["front_app": frontApp, "window": window, "window_count": windowCount, "sheet_count": sheetCount,
             "focused": focus, "value": String(value.prefix(120))]
        }
    }

    @MainActor
    static func focusSnapshot(pid: pid_t) -> FocusSnapshot {
        var s = FocusSnapshot()
        s.frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        guard let appEl = Element.application(for: pid) else { return s }
        let windows = appEl.windows() ?? []
        s.windowCount = windows.count
        s.sheetCount = windows.reduce(0) { $0 + ($1.children()?.filter { $0.role() == "AXSheet" }.count ?? 0) }
        if let win = appEl.focusedWindow() { s.window = win.title() ?? "" }
        if let el = appEl.focusedUIElement() {
            let name = el.title() ?? el.descriptionText() ?? ""
            s.focus = (el.role() ?? "?") + (name.isEmpty ? "" : " '\(name)'")
            s.value = currentText(el) ?? ""
        }
        return s
    }

    // MARK: - Parsing

    struct KeyCombo: CustomStringConvertible {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
        var name: String
        var repeatCount = 1
        var impliedShift = false   // "?" / "A" / "+" — shift comes from the character, not the caller
        var description: String {
            var parts: [String] = []
            if flags.contains(.maskControl) { parts.append("ctrl") }
            if flags.contains(.maskAlternate) { parts.append("option") }
            if flags.contains(.maskShift), !impliedShift { parts.append("shift") }
            if flags.contains(.maskCommand) { parts.append("cmd") }
            if flags.contains(.maskSecondaryFn) { parts.append("fn") }
            parts.append(name)
            return parts.joined(separator: "+") + (repeatCount > 1 ? "*\(repeatCount)" : "")
        }
    }

    struct KeyParseError: Error, CustomStringConvertible {
        let description: String
    }

    static let namedKeys: [String: CGKeyCode] = [
        "return": 0x24, "enter": 0x24, "⏎": 0x24, "↩": 0x24, "kpenter": 0x4C,
        "tab": 0x30, "⇥": 0x30, "space": 0x31, "spacebar": 0x31,
        "delete": 0x33, "backspace": 0x33, "⌫": 0x33,
        "forwarddelete": 0x75, "fwddelete": 0x75, "del": 0x75, "⌦": 0x75,
        "escape": 0x35, "esc": 0x35, "⎋": 0x35,
        "up": 0x7E, "uparrow": 0x7E, "↑": 0x7E, "down": 0x7D, "downarrow": 0x7D, "↓": 0x7D,
        "left": 0x7B, "leftarrow": 0x7B, "←": 0x7B, "right": 0x7C, "rightarrow": 0x7C, "→": 0x7C,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pgup": 0x74, "pagedown": 0x79, "pgdn": 0x79,
        "help": 0x72,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71,
        "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
        "plus": 0x18, "minus": 0x1B, "comma": 0x2B, "period": 0x2F,
    ]

    static let modifierNames: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand, "meta": .maskCommand,
        "shift": .maskShift, "⇧": .maskShift,
        "option": .maskAlternate, "opt": .maskAlternate, "alt": .maskAlternate, "⌥": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
        "fn": .maskSecondaryFn, "function": .maskSecondaryFn,
    ]

    /// "cmd+shift+n down*3 return" → combos. A combo's last part is the key; "+" itself is "cmd++".
    @MainActor
    static func parseKeySequence(_ keys: String) throws -> [KeyCombo] {
        let layout = layoutKeyMap()
        return try keys.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map { raw in
            var token = String(raw)
            var repeatCount = 1
            if let star = token.lastIndex(of: "*"), star != token.startIndex,
               let n = Int(token[token.index(after: star)...]), n > 0 {
                repeatCount = min(n, 100)
                token = String(token[..<star])
            }
            // Leading symbol modifiers: "⌘⇧T"
            var flags: CGEventFlags = []
            while let first = token.first, let f = modifierNames[String(first)], token.count > 1 {
                flags.insert(f); token.removeFirst()
            }
            var parts = token.components(separatedBy: "+")
            if token.hasSuffix("++") || token == "+" { parts = Array(token.dropLast().components(separatedBy: "+").dropLast()) + ["+"] }
            parts = parts.filter { !$0.isEmpty }
            guard let keyPart = parts.last else { throw KeyParseError(description: "Empty key in \"\(raw)\"") }
            for mod in parts.dropLast() {
                guard let f = modifierNames[mod.lowercased()] else {
                    throw KeyParseError(description: "Unknown modifier \"\(mod)\" in \"\(raw)\" — use cmd, shift, option, ctrl, fn.")
                }
                flags.insert(f)
            }
            if let code = namedKeys[keyPart.lowercased()] {
                return KeyCombo(keyCode: code, flags: flags, name: keyPart.lowercased(), repeatCount: repeatCount)
            }
            guard keyPart.count == 1, let ch = keyPart.first else {
                throw KeyParseError(description: "Unknown key \"\(keyPart)\" in \"\(raw)\". Use a single character or one of: return, tab, space, delete, forwarddelete, escape, up, down, left, right, home, end, pageup, pagedown, f1–f20. To type words use text.")
            }
            // With a modifier, a letter means its key (cmd+S == cmd+s, like menu shortcuts);
            // alone, an uppercase letter or symbol adds shift as needed.
            let lookup: Character = flags.isEmpty ? ch : Character(String(ch).lowercased())
            if let (code, shift) = layout[lookup] ?? usKeyMap[lookup] {
                let implied = shift && !flags.contains(.maskShift)
                if shift { flags.insert(.maskShift) }
                return KeyCombo(keyCode: code, flags: flags, name: String(lookup), repeatCount: repeatCount, impliedShift: implied)
            }
            throw KeyParseError(description: "No key on the current keyboard layout types \"\(ch)\" — use text to type it.")
        }
    }

    /// Character → (virtual key code, needs shift) for the current keyboard layout,
    /// so "cmd+z" hits Z on AZERTY/QWERTZ too. Keypad keys are skipped.
    @MainActor
    static func layoutKeyMap() -> [Character: (CGKeyCode, Bool)] {
        var map: [Character: (CGKeyCode, Bool)] = [:]
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return map }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for shift in [false, true] {
                for code in 0..<0x41 {   // 0x41+ is the keypad / function keys
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                                &dead, chars.count, &length, &chars)
                    guard status == noErr, length == 1,
                          let ch = String(utf16CodeUnits: chars, count: length).first,
                          !ch.isWhitespace, ch.asciiValue.map({ $0 >= 0x20 }) ?? true,
                          map[ch] == nil else { continue }
                    map[ch] = (CGKeyCode(code), shift)
                }
            }
        }
        return map
    }

    /// US ANSI fallback when the layout lookup fails.
    static let usKeyMap: [Character: (CGKeyCode, Bool)] = {
        var m: [Character: (CGKeyCode, Bool)] = [:]
        let plain: [(String, CGKeyCode)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07),
            ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10),
            ("t", 0x11), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16), ("5", 0x17), ("=", 0x18),
            ("9", 0x19), ("7", 0x1A), ("-", 0x1B), ("8", 0x1C), ("0", 0x1D), ("]", 0x1E), ("o", 0x1F), ("u", 0x20),
            ("[", 0x21), ("i", 0x22), ("p", 0x23), ("l", 0x25), ("j", 0x26), ("'", 0x27), ("k", 0x28), (";", 0x29),
            ("\\", 0x2A), (",", 0x2B), ("/", 0x2C), ("n", 0x2D), ("m", 0x2E), (".", 0x2F), ("`", 0x32),
        ]
        for (c, k) in plain { m[Character(c)] = (k, false) }
        let shifted: [(String, String)] = [
            ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"), ("^", "6"), ("&", "7"), ("*", "8"), ("(", "9"),
            (")", "0"), ("_", "-"), ("+", "="), ("{", "["), ("}", "]"), ("|", "\\"), (":", ";"), ("\"", "'"),
            ("<", ","), (">", "."), ("?", "/"), ("~", "`"),
        ]
        for (s, base) in shifted { if let k = m[Character(base)]?.0 { m[Character(s)] = (k, true) } }
        for c in "abcdefghijklmnopqrstuvwxyz" { if let k = m[c]?.0 { m[Character(c.uppercased())] = (k, true) } }
        return m
    }()

    // MARK: - Posting

    static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskControl, 0x3B), (.maskAlternate, 0x3A), (.maskShift, 0x38), (.maskCommand, 0x37),
    ]

    /// Modifier downs, key down/up with flags, modifier ups — like a real keyboard,
    /// so apps that read modifier state (not just event flags) see them too.
    static func post(_ combo: KeyCombo) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        var events: [CGEvent] = []
        var active: CGEventFlags = []
        let mods = modifierKeyCodes.filter { combo.flags.contains($0.0) }
        for (flag, code) in mods {
            active.insert(flag)
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { throw KeyParseError(description: "Could not create key event") }
            e.flags = active
            events.append(e)
        }
        if combo.flags.contains(.maskSecondaryFn) { active.insert(.maskSecondaryFn) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down) else { throw KeyParseError(description: "Could not create key event") }
            e.flags = active
            events.append(e)
        }
        active.remove(.maskSecondaryFn)
        for (flag, code) in mods.reversed() {
            active.remove(flag)
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw KeyParseError(description: "Could not create key event") }
            e.flags = active
            events.append(e)
        }
        for e in events {
            e.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
