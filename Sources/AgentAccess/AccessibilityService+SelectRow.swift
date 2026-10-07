import AgentAudit
import AXorcist
import ApplicationServices
import Foundation
import AppKit

// MARK: - Select Row

extension AccessibilityService {

    /// Select the row of a table / outline / list whose cell text matches `rowText`
    /// (exact cell, then cell prefix, then contains — case-insensitive), scroll it into
    /// view and verify it's selected — the accessibility equivalent of AppleScript's
    /// `select (first row of table 1 whose value of text field 1 is "X")`, in any app.
    /// role/title/value pick the container; with none given, the first table/outline/list
    /// of the app's front window is used. `open: true` then opens the row (AXOpen, else
    /// a double-click) — like double-clicking a file in Finder.
    @MainActor
    public func selectRow(role: String?, title: String?, value: String?, appBundleId: String?, rowText: String, open: Bool = false) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "selectRow(role: \(role ?? "nil"), title: \(title ?? "nil"), row: \(rowText), open: \(open), app: \(appBundleId ?? "frontmost"))")

        var scopes: [Element] = []
        if role != nil || title != nil || value != nil {
            guard let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) else {
                return errorJSON("Element not found: role=\(role ?? "any"), title=\(title ?? "any")")
            }
            scopes = [found]
        } else {
            let bundleId = resolveBundleId(appBundleId)
            let runningApp = bundleId.flatMap { RunningApplicationHelper.applications(withBundleIdentifier: $0).first }
                ?? RunningApplicationHelper.frontmostApplication
            guard let app = runningApp, let appElement = Element.application(for: app) else {
                return errorJSON("App not running or not answering accessibility queries: \(appBundleId ?? "frontmost")")
            }
            if let window = appElement.focusedWindow() ?? appElement.mainWindow() ?? appElement.windows()?.first {
                scopes.append(window)
            }
            // App-level content that isn't a window — Finder's desktop is
            // `scroll area "desktop"` of the app, holding the desktop icons.
            scopes += (appElement.children(strict: true) ?? []).filter { $0.role() == "AXScrollArea" }
            if scopes.isEmpty { scopes = [appElement] }
        }
        // Every table/outline/list/icon view in scope, biggest first (main content
        // before sidebar), the front window before the desktop.
        let containers = scopes.flatMap { Self.rowContainers(in: $0) }
        guard !containers.isEmpty else {
            return errorJSON("No table, outline, list or icon view found")
        }

        let want = rowText.lowercased().trimmingCharacters(in: .whitespaces)
        var all: [(row: Element, cells: [String], container: Element)] = []
        for c in containers {
            for row in Self.rowsOf(c) {
                all.append((row, Self.rowTexts(row), c))
            }
        }
        let match = all.first { $0.cells.contains { $0.lowercased() == want } }
            ?? all.first { $0.cells.contains { $0.lowercased().hasPrefix(want) } }
            ?? all.first { $0.cells.contains { $0.lowercased().contains(want) } }
        guard let hit = match else {
            let names = all.compactMap(\.cells.first).prefix(60).joined(separator: " | ")
            return errorJSON("No row matching '\(rowText)'. Rows: \(names)")
        }
        let pick = hit.row
        let container = hit.container
        let containerRole = container.role() ?? "?"

        let cells = hit.cells.joined(separator: " | ")

        _ = AXUIElementPerformAction(pick.underlyingElement, "AXScrollToVisible" as CFString)
        func isSelected() -> Bool { pick.attribute(Attribute<Bool>("AXSelected")) ?? false }
        var clickBlocked: String?
        if !isSelected() {
            // Rows of NSTableView/NSOutlineView accept AXSelected; fall back to the
            // container's AXSelectedRows, then a plain click.
            // Icon views (Finder desktop) only take AXSelectedChildren on the group;
            // AX reports success for attributes an element lacks, so set by role.
            if !pick.setValue(true, forAttribute: "AXSelected") {
                let attr = container.role() == "AXGroup" ? "AXSelectedChildren" : "AXSelectedRows"
                _ = container.setValue([pick.underlyingElement] as CFArray, forAttribute: attr)
            }
            let deadline = Date().addingTimeInterval(1.0)
            while !isSelected(), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if !isSelected(), let pid = pick.pid() {
                // Mouse only when the click lands on the row/icon itself — a desktop
                // icon behind a window would otherwise click that window.
                if let reason = Self.mouseClickBlocker(pick, pid: pid) {
                    clickBlocked = reason
                } else {
                    _ = try? pick.click()
                    let d2 = Date().addingTimeInterval(1.0)
                    while !isSelected(), Date() < d2 { Thread.sleep(forTimeInterval: 0.05) }
                }
            }
        }
        let selected = isSelected()
        // Opening doesn't need the selection: AXOpen works on covered desktop icons.
        guard selected || (open && pick.isActionSupported("AXOpen")) else {
            return errorJSON("Found row '\(cells)' but could not select it" + (clickBlocked.map { " — \($0); bring its window forward or use open:true" } ?? ""))
        }
        var result: [String: Any] = ["message": "Selected row '\(cells)' in \(containerRole)", "row": cells]

        if open {
            if AXUIElementPerformAction(pick.underlyingElement, "AXOpen" as CFString) != .success {
                do {
                    try pick.click(clickCount: 2)
                } catch {
                    return errorJSON("Selected row '\(cells)' but could not open it: \(error.localizedDescription)")
                }
            }
            result["message"] = "\(selected ? "Selected and opened" : "Opened") row '\(cells)' in \(containerRole)"
            result["opened"] = true
        }
        return successJSON(result)
    }

    /// Every table/outline/list at or under `el`, biggest on screen first, so the main
    /// content view wins over a sidebar when both have a matching row.
    @MainActor
    static func rowContainers(in el: Element) -> [Element] {
        let containers: Set<String> = ["AXTable", "AXOutline", "AXList"]
        var found: [Element] = []
        var queue: [(Element, Int)] = [(el, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 3000, found.count < 12 {
            let (cur, depth) = queue.removeFirst()
            visited += 1
            if cur.isHidden() == true { continue }
            if let r = cur.role(), containers.contains(r) {
                found.append(cur)
                continue
            }
            // Icon views (Finder desktop / icon-view windows): a group of AXImage
            // items that carry AXSelected — the icon-view counterpart of a list.
            if cur.role() == "AXGroup", let kids = cur.children(strict: true),
               kids.contains(where: { $0.role() == "AXImage" && $0.attribute(Attribute<Bool>("AXSelected")) != nil }) {
                found.append(cur)
                continue
            }
            guard depth < 25 else { continue }
            for child in cur.children(strict: true) ?? [] { queue.append((child, depth + 1)) }
        }
        func area(_ e: Element) -> CGFloat { e.frame().map { $0.width * $0.height } ?? 0 }
        return found.sorted { area($0) > area($1) }
    }

    /// Cell texts of a row; for list items with no cells, the item's own text.
    @MainActor
    static func rowTexts(_ row: Element) -> [String] {
        let cells = rowCellTexts(row)
        if !cells.isEmpty { return cells }
        return ownText(row, role: row.role() ?? "").map { [$0] } ?? []
    }


    /// Rows of a table/outline (AXRows) or the selectable children of a list.
    @MainActor
    static func rowsOf(_ container: Element) -> [Element] {
        if let rows = container.rows(), !rows.isEmpty { return rows }
        return (container.children(strict: true) ?? []).filter { $0.role() != "AXScrollBar" }
    }
}
