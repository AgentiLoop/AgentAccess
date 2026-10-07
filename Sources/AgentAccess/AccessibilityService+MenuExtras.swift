import AgentAudit
import AXorcist
import Foundation
import AppKit

// MARK: - Menu Bar Extras (status items)

extension AccessibilityService {

    /// Menu-bar extras (right side of the menu bar: Wi‑Fi, Battery, Control Center,
    /// third-party status items) — AppleScript's `menu bar 2 of process "X"`.
    @MainActor
    static func extrasMenuBar(of app: Element) -> Element? {
        guard let ui: AXUIElement = app.attribute(Attribute<AXUIElement>("AXExtrasMenuBar")) else { return nil }
        return Element(ui)
    }

    /// Every name a menu extra answers to: description ("Wi‑Fi"), title, identifier.
    @MainActor
    static func menuExtraLabels(_ el: Element) -> [String] {
        [el.descriptionText(), el.title(), el.identifier(), el.help()]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    /// Lowercased, hyphen variants (‑ – —) folded to "-", trailing ellipsis removed.
    static func normalizeExtraLabel(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for h in ["\u{2011}", "\u{2010}", "\u{2013}", "\u{2014}"] {
            t = t.replacingOccurrences(of: h, with: "-")
        }
        while t.hasSuffix("…") { t = String(t.dropLast()) }
        while t.hasSuffix("...") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Best element whose labels match `name`: exact → prefix → contains.
    @MainActor
    static func bestLabelMatch(name: String, in elements: [Element], labels: (Element) -> [String]) -> Element? {
        let want = normalizeExtraLabel(name)
        guard !want.isEmpty else { return nil }
        var prefix: Element?
        var contains: Element?
        for el in elements {
            for label in labels(el).map(normalizeExtraLabel) where !label.isEmpty {
                if label == want { return el }
                if prefix == nil, label.hasPrefix(want) { prefix = el }
                if contains == nil, label.contains(want) { contains = el }
            }
        }
        return prefix ?? contains
    }

    /// Click a menu-bar extra by name, then walk the rest of `menuPath` inside its
    /// menu (or, for popovers like Control Center's modules, inside the panel it
    /// opens). Searches `appElement`'s extras first, then every running app's when
    /// `scanAll` is set. Returns nil only when no extra matched AND nothing else
    /// useful can be said (caller then reports its own main-menu error).
    @MainActor
    func clickMenuExtra(appElement: Element?, scanAll: Bool, menuPath: [String]) -> String? {
        guard let first = menuPath.first else { return nil }

        var candidates: [(app: Element, item: Element)] = []
        func collect(from app: Element) {
            guard let bar = Self.extrasMenuBar(of: app) else { return }
            // macOS 26+ MenuBarAgent wraps each extra in an AXGroup — unwrap to the AXMenuBarItem.
            func add(_ el: Element, depth: Int) {
                if el.role() == "AXMenuBarItem" || depth >= 3 { candidates.append((app, el)); return }
                let kids = el.children(strict: true) ?? []
                if kids.isEmpty { candidates.append((app, el)); return }
                for kid in kids { add(kid, depth: depth + 1) }
            }
            for item in bar.children(strict: true) ?? [] { add(item, depth: 0) }
        }
        if let appElement { collect(from: appElement) }
        var match = Self.bestLabelMatch(name: first, in: candidates.map(\.item), labels: Self.menuExtraLabels)
        if match == nil, scanAll {
            for running in NSWorkspace.shared.runningApplications where !running.isTerminated {
                guard let app = Element.application(for: running) else { continue }
                app.setMessagingTimeout(0.5)
                collect(from: app)
            }
            match = Self.bestLabelMatch(name: first, in: candidates.map(\.item), labels: Self.menuExtraLabels)
        }
        guard let extra = match, let owner = candidates.first(where: { $0.item == extra })?.app else {
            if candidates.isEmpty { return nil }
            let names = candidates.compactMap { Self.menuExtraLabels($0.item).first }
            return errorJSON("'\(first)' is not in the app menu bar or the menu-bar extras. Extras: \(names.prefix(40).joined(separator: ", "))")
        }
        let extraName = Self.menuExtraLabels(extra).first ?? first
        AuditLog.log(.accessibility, "clickMenuExtra(\(extraName), path: \(menuPath.joined(separator: " > ")))")

        do {
            try extra.performAction(.press)
        } catch {
            return errorJSON("Failed to press menu-bar extra '\(extraName)'")
        }
        Thread.sleep(forTimeInterval: 0.35)

        let rest = Array(menuPath.dropFirst())
        let menu = (extra.children(strict: true) ?? []).first { $0.role() == "AXMenu" }

        if rest.isEmpty {
            var result: [String: Any] = ["message": "Opened menu-bar extra '\(extraName)'", "matched": extraName]
            if let menu {
                result["items"] = (menu.children(strict: true) ?? []).compactMap { $0.title() }.filter { !$0.isEmpty }
            }
            return successJSON(result)
        }

        // Real NSMenu: walk it like the main menu.
        if let menu {
            var current = menu
            for (i, name) in rest.enumerated() {
                let items = current.children(strict: true) ?? []
                guard let item = Self.bestLabelMatch(name: name, in: items, labels: { [$0.title() ?? ""] }) else {
                    let available = items.compactMap { $0.title() }.filter { !$0.isEmpty }
                    _ = try? menu.performAction(.cancel)
                    return errorJSON("Menu item '\(name)' not found in '\(extraName)'. Available: \(available.prefix(40).joined(separator: ", "))")
                }
                if i == rest.count - 1 {
                    if item.isEnabled() == false {
                        _ = try? menu.performAction(.cancel)
                        return errorJSON("Menu item '\(item.title() ?? name)' is disabled (grayed out) right now")
                    }
                    do { try item.performAction(.press) } catch {
                        _ = try? menu.performAction(.cancel)
                        return errorJSON("Failed to press menu item: \(item.title() ?? name)")
                    }
                    return successJSON([
                        "message": "Clicked menu: \(([extraName] + rest).joined(separator: " > "))",
                        "matched": item.title() ?? name
                    ])
                }
                _ = try? item.performAction(.press)
                Thread.sleep(forTimeInterval: 0.15)
                current = (item.children(strict: true) ?? []).first { $0.role() == "AXMenu" } ?? item
            }
        }

        // Popover/panel (Control Center modules, etc.): find each name in the panel's
        // windows. The panel is often another process (MenuBarAgent's Wi‑Fi extra opens
        // a Control Center window) — ask whoever owns the screen just below the extra.
        var panelApps = [owner]
        if let f = extra.frame(),
           let pid = Element.elementAtPoint(CGPoint(x: f.midX, y: f.maxY + 40))?.pid(),
           pid != owner.pid(), let panelApp = Element.application(for: pid) {
            panelApps.insert(panelApp, at: 0)
        }
        for (i, name) in rest.enumerated() {
            if i > 0 { Thread.sleep(forTimeInterval: 0.35) }
            let windows = panelApps.flatMap { $0.windows() ?? [] }
            var all: [Element] = []
            func gather(_ el: Element, depth: Int) {
                guard depth <= 25, all.count < 3000 else { return }
                all.append(el)
                for child in el.children(strict: true) ?? [] { gather(child, depth: depth + 1) }
            }
            for window in windows { for child in window.children(strict: true) ?? [] { gather(child, depth: 0) } }
            let labels: (Element) -> [String] = { [$0.title(), $0.descriptionText(), $0.value() as? String, $0.identifier()].compactMap { $0 } }
            // Prefer things that can be pressed over static labels with the same text.
            let pressable = all.filter { ["AXButton", "AXCheckBox", "AXRadioButton", "AXSwitch", "AXMenuItem", "AXDisclosureTriangle", "AXPopUpButton", "AXMenuButton", "AXLink", "AXToggle"].contains($0.role() ?? "") }
            guard let target = Self.bestLabelMatch(name: name, in: pressable, labels: labels)
                ?? Self.bestLabelMatch(name: name, in: all, labels: labels) else {
                let available = pressable.compactMap { labels($0).first(where: { !$0.isEmpty }) }
                _ = try? extra.performAction(.press) // toggle the panel closed again
                return errorJSON("'\(name)' not found in the '\(extraName)' panel. Available: \(available.prefix(40).joined(separator: ", "))")
            }
            let label = labels(target).first(where: { !$0.isEmpty }) ?? name
            do { try target.performAction(.press) } catch {
                return errorJSON("Failed to press '\(label)' in the '\(extraName)' panel")
            }
            if i == rest.count - 1 {
                return successJSON([
                    "message": "Clicked: \(([extraName] + rest).joined(separator: " > "))",
                    "matched": label
                ])
            }
        }
        return errorJSON("Menu item not found: \(menuPath.joined(separator: " > "))")
    }
}
