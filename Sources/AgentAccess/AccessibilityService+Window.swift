import AgentAudit
import AXorcist
import Foundation
import AppKit

extension AccessibilityService {
    // MARK: - Frontmost Window

    @MainActor
    public static func frontmostWindowID() -> UInt32? {
        guard let app = RunningApplicationHelper.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let windowList = WindowInfoHelper.getWindows(for: pid) else { return nil }
        for window in windowList {
            guard let windowID = window[CFConstants.cgWindowNumber] as? UInt32,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            return windowID
        }
        return nil
    }

    // MARK: - Highlight Element

    @MainActor
    public func highlightElement(
        role: String?, title: String?, value: String?, appBundleId: String?,
        x: CGFloat?, y: CGFloat?,
        duration: TimeInterval = 2.0, color: String = "green"
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "highlightElement(role: \(role ?? "nil"), title: \(title ?? "nil"), value: \(value ?? "nil"), app: \(appBundleId ?? "nil"), duration: \(duration)s)")

        var element: Element?

        if let x = x, let y = y {
            element = Element.elementAtPoint(CGPoint(x: x, y: y))
        } else {
            element = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId)
        }

        guard let found = element else {
            return errorJSON("Element not found for highlighting")
        }

        guard let frame = found.frame() else {
            return errorJSON("Could not get element position")
        }

        let highlightColor: NSColor
        switch color.lowercased() {
        case "red": highlightColor = NSColor.red.withAlphaComponent(0.3)
        case "blue": highlightColor = NSColor.blue.withAlphaComponent(0.3)
        case "yellow": highlightColor = NSColor.yellow.withAlphaComponent(0.3)
        case "purple": highlightColor = NSColor.purple.withAlphaComponent(0.3)
        default: highlightColor = NSColor.green.withAlphaComponent(0.3)
        }

        DispatchQueue.main.async {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .floating
            window.backgroundColor = highlightColor
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { window.close() }
        }

        return successJSON([
            "message": "Element highlighted for \(duration) seconds",
            "bounds": ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height],
            "color": color, "duration": duration
        ])
    }

    // MARK: - Get Window Frame

    @MainActor
    public func getWindowFrame(windowId: Int) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "getWindowFrame(windowId: \(windowId))")

        // Use AXorcist WindowInfoHelper to get window bounds
        if let bounds = WindowInfoHelper.getWindowBounds(windowID: CGWindowID(windowId)) {
            let ownerPID = WindowInfoHelper.getOwnerPID(windowID: CGWindowID(windowId)) ?? 0
            let windowName = WindowInfoHelper.getWindowName(windowID: CGWindowID(windowId)) ?? ""
            let appName = getProcessName(pid: ownerPID) ?? "Unknown"

            return successJSON([
                "windowId": windowId, "ownerPID": Int(ownerPID), "ownerName": appName,
                "windowName": windowName,
                "frame": ["x": bounds.origin.x, "y": bounds.origin.y, "width": bounds.width, "height": bounds.height]
            ])
        }
        return errorJSON("Window \(windowId) not found")
    }

    // MARK: - Menu Bar Navigation

    @MainActor
    public func clickMenuItem(appBundleId: String?, menuPath: [String]) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "clickMenuItem(app: \(appBundleId ?? "frontmost"), path: \(menuPath.joined(separator: " > ")))")
        guard !menuPath.isEmpty else { return errorJSON("Menu path cannot be empty") }

        let appElement: Element?
        if let bundleId = appBundleId,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first {
            appElement = Element.application(for: app)
        } else if let app = RunningApplicationHelper.frontmostApplication {
            appElement = Element.application(for: app)
        } else {
            return errorJSON("No frontmost app")
        }

        guard let root = appElement, let menuBar = root.mainMenu() else {
            return errorJSON("Could not access menu bar")
        }

        var current = menuBar
        for (i, menuName) in menuPath.enumerated() {
            guard let children = current.children() else {
                return errorJSON("Could not get children at level \(i) ('\(menuName)')")
            }
            guard let child = Self.bestMenuMatch(name: menuName, in: children) else {
                let available = children.compactMap { $0.title() }.filter { !$0.isEmpty }
                var err = "Menu '\(menuName)' not found at level \(i)."
                if !available.isEmpty {
                    err += " Available: \(available.prefix(30).joined(separator: ", "))"
                }
                return errorJSON(err)
            }
            if i == menuPath.count - 1 {
                if child.isEnabled() == false {
                    return errorJSON("Menu item '\(child.title() ?? menuName)' is disabled (grayed out) right now")
                }
                do {
                    try child.performAction(.press)
                    return successJSON([
                        "message": "Clicked menu: \(menuPath.joined(separator: " > "))",
                        "matched": child.title() ?? menuName
                    ])
                } catch {
                    return errorJSON("Failed to press menu item: \(child.title() ?? menuName)")
                }
            } else {
                _ = try? child.performAction(.press)
                Thread.sleep(forTimeInterval: 0.15)
                if let subs = child.children(), let first = subs.first {
                    current = first
                } else {
                    current = child
                }
            }
        }
        return errorJSON("Menu item not found: \(menuPath.joined(separator: " > "))")
    }

    /// Normalize a menu title for tolerant matching: trim, lowercase, strip
    /// trailing ellipsis ("…" or "..."). "Save As" then matches "Save As…".
    private static func normalizeMenuTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while t.hasSuffix("…") {
            t = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        while t.hasSuffix("...") {
            t = String(t.dropLast(3)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// Find the best-matching child menu element for a requested name.
    /// Match order: exact (normalized) → prefix → contains. Case and trailing
    /// ellipsis are ignored so LLM-supplied paths survive cosmetic differences.
    @MainActor
    private static func bestMenuMatch(name: String, in children: [Element]) -> Element? {
        let want = normalizeMenuTitle(name)
        guard !want.isEmpty else { return nil }
        var prefixMatch: Element?
        var containsMatch: Element?
        for child in children {
            guard let title = child.title(), !title.isEmpty else { continue }
            let have = normalizeMenuTitle(title)
            if have == want { return child }
            if prefixMatch == nil, have.hasPrefix(want) { prefixMatch = child }
            if containsMatch == nil, have.contains(want) { containsMatch = child }
        }
        return prefixMatch ?? containsMatch
    }

    // MARK: - Window Move / Resize

    @MainActor
    public func setWindowFrame(appBundleId: String?, x: CGFloat?, y: CGFloat?, width: CGFloat?, height: CGFloat?) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "setWindowFrame(app: \(appBundleId ?? "frontmost"), x: \(x ?? -1), y: \(y ?? -1), w: \(width ?? -1), h: \(height ?? -1))")

        let appElement: Element?
        if let bundleId = appBundleId,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first {
            appElement = Element.application(for: app)
        } else if let app = RunningApplicationHelper.frontmostApplication {
            appElement = Element.application(for: app)
        } else {
            return errorJSON("No frontmost app")
        }

        guard let root = appElement,
              let appWindows = root.windows(),
              let window = appWindows.first(where: { $0.role() == "AXWindow" }) else {
            return errorJSON("No windows found")
        }

        if let x, let y {
            _ = window.setPosition(CGPoint(x: x, y: y))
        }
        if let width, let height {
            _ = window.setSize(CGSize(width: width, height: height))
        }

        return successJSON(["message": "Window frame updated"])
    }

    // MARK: - App Launch / Activate / Quit

    @MainActor
    public func manageApp(action: String, bundleId: String?, name: String?) -> String {
        AuditLog.log(.accessibility, "manageApp(action: \(action), bundleId: \(bundleId ?? "nil"), name: \(name ?? "nil"))")

        // Normalize inputs: callers frequently pass a natural app name like
        // "Photo Booth" in the `bundleId` slot (it's the only field the
        // dispatcher forwards). If `bundleId` lacks a dot it can't be a real
        // reverse-DNS bundle ID — promote it to `name` so the name-resolution
        // paths below (resolveBundleId + directory scan) get a chance to run.
        var bundleId = bundleId
        var name = name
        if let bid = bundleId, !bid.contains(".") {
            if name == nil { name = bid }
            bundleId = nil
        }

        switch action {
        case "launch":
            // App launching requires NSWorkspace — this is expected
            if let bid = bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return successJSON(["message": "Launched \(bid)"])
            } else if let n = name {
                // Resolve name → bundle ID via SDEF catalog + installed-apps scan
                // (covers /Applications, /System/Applications, ~/Applications).
                if let resolvedBid = resolveBundleId(n),
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: resolvedBid) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    return successJSON(["message": "Launched \(resolvedBid)"])
                }
                // Fallback: check common .app locations directly by name.
                for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
                    let url = URL(fileURLWithPath: "\(dir)/\(n).app")
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        return successJSON(["message": "Launched \(n)"])
                    }
                }
                return errorJSON("App not found: \(n)")
            }
            return errorJSON("Specify bundleId or name")
        case "activate":
            // AXorcist: use Element.activate() to bring app forward
            if let bid = bundleId, let app = RunningApplicationHelper.applications(withBundleIdentifier: bid).first,
               let appElement = Element.application(for: app) {
                _ = appElement.activate()
                return successJSON(["message": "Activated \(bid)"])
            } else if let n = name {
                // Try resolved bundle ID first, then fall back to localizedName match.
                if let resolvedBid = resolveBundleId(n),
                   let app = RunningApplicationHelper.applications(withBundleIdentifier: resolvedBid).first,
                   let appElement = Element.application(for: app) {
                    _ = appElement.activate()
                    return successJSON(["message": "Activated \(resolvedBid)"])
                }
                if let app = RunningApplicationHelper.allApplications().first(where: { $0.localizedName == n }),
                   let appElement = Element.application(for: app) {
                    _ = appElement.activate()
                    return successJSON(["message": "Activated \(n)"])
                }
            }
            return errorJSON("App not running")
        case "hide", "unhide":
            // AXorcist: Element.hideApplication() / unhideApplication().
            // Resolve names via lookupBundleId (pure — no auto-launch: launching
            // an app just to hide it would be absurd), then fall back to a
            // localizedName match against running apps.
            let resolvedBid = bundleId ?? name.flatMap { lookupBundleId($0) }
            var targetApp: NSRunningApplication?
            if let bid = resolvedBid {
                targetApp = RunningApplicationHelper.applications(withBundleIdentifier: bid).first
            }
            if targetApp == nil, let n = name {
                targetApp = RunningApplicationHelper.allApplications()
                    .first(where: { ($0.localizedName ?? "").lowercased() == n.lowercased() })
            }
            guard let app = targetApp, let appElement = Element.application(for: app) else {
                return errorJSON("App not running")
            }
            if action == "hide" {
                _ = appElement.hideApplication()
                return successJSON(["message": "Hidden \(app.bundleIdentifier ?? name ?? "app")"])
            } else {
                _ = appElement.unhideApplication()
                return successJSON(["message": "Unhidden \(app.bundleIdentifier ?? name ?? "app")"])
            }
        case "quit":
            if let bid = bundleId, let app = RunningApplicationHelper.applications(withBundleIdentifier: bid).first {
                app.terminate()
                return successJSON(["message": "Quit \(bid)"])
            } else if let n = name {
                if let resolvedBid = resolveBundleId(n),
                   let app = RunningApplicationHelper.applications(withBundleIdentifier: resolvedBid).first {
                    app.terminate()
                    return successJSON(["message": "Quit \(resolvedBid)"])
                }
                if let app = RunningApplicationHelper.allApplications().first(where: { $0.localizedName == n }) {
                    app.terminate()
                    return successJSON(["message": "Quit \(n)"])
                }
            }
            return errorJSON("App not running")
        case "list":
            let apps = RunningApplicationHelper.filteredApplications(options: .init(excludeProhibitedApps: true))
                .map { "\($0.localizedName ?? "?") — \($0.bundleIdentifier ?? "?")\($0.isActive ? " (active)" : "")" }
            return successJSON(["apps": apps])
        default:
            return errorJSON("Unknown action: \(action). Use launch, activate, hide, unhide, quit, or list.")
        }
    }

    // MARK: - Scroll to AX Element

    @MainActor
    /// Scroll the app's main scroll area until the target element becomes findable.
    /// AXorcist-only: walks the focused window for the first AXScrollArea and calls
    /// `Element.scroll(direction:amount:)` on it. The old implementation drove a
    /// scroll wheel via InputDriver at the window center; that's gone.
    public func scrollToElement(role: String?, title: String?, appBundleId: String?, maxScrolls: Int = 20) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "scrollToElement(role: \(role ?? "nil"), title: \(title ?? "nil"), app: \(appBundleId ?? "nil"))")

        if findAXElement(role: role, title: title, value: nil, appBundleId: appBundleId) != nil {
            return successJSON(["message": "Element already visible", "scrolls": 0])
        }

        // Resolve the app element via AXorcist
        let appElement: Element?
        if let bundleId = appBundleId,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first {
            appElement = Element.application(for: app)
        } else if let app = RunningApplicationHelper.frontmostApplication {
            appElement = Element.application(for: app)
        } else {
            return errorJSON("No app to scroll in")
        }
        guard let root = appElement else {
            return errorJSON("Could not get app element for \(appBundleId ?? "frontmost")")
        }

        // Find the first AXScrollArea inside any window — that's the AXorcist-native
        // scroll target. If the app has no scroll area we can't scroll via accessibility.
        let scrollAreas = root.findElements(role: "AXScrollArea", title: nil, label: nil, value: nil, identifier: nil, maxDepth: 10)
        guard let scrollArea = scrollAreas.first else {
            return errorJSON("No AXScrollArea found in \(appBundleId ?? "frontmost app"). The app may use a custom non-accessible scroll view.")
        }

        for i in 0..<maxScrolls {
            do {
                try scrollArea.scroll(direction: .down, amount: 5)
            } catch {
                return errorJSON("Element.scroll failed: \(error.localizedDescription)")
            }
            Thread.sleep(forTimeInterval: 0.3)
            if findAXElement(role: role, title: title, value: nil, appBundleId: appBundleId) != nil {
                return successJSON(["message": "Found element after scrolling", "scrolls": i + 1])
            }
        }

        return errorJSON("Element not found after \(maxScrolls) scrolls")
    }

    // MARK: - Read Focused Element

    @MainActor
    public func readFocusedElement(appBundleId: String? = nil) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "readFocusedElement(app: \(appBundleId ?? "frontmost"))")

        let appElement: Element?
        if let bundleId = appBundleId,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first {
            appElement = Element.application(for: app)
        } else if let app = RunningApplicationHelper.frontmostApplication {
            appElement = Element.application(for: app)
        } else {
            return errorJSON("No frontmost app")
        }

        guard let root = appElement else { return errorJSON("No app element") }

        // AXorcist: use focusedUIElement for getting focused element within the app
        if let focused = root.focusedUIElement() {
            return successJSON(elementProperties(focused))
        }
        // Fallback: try focusedApplicationElement
        if let focused = root.focusedApplicationElement() {
            return successJSON(elementProperties(focused))
        }
        return errorJSON("No focused element")
    }

    /// Get recent audit log entries
    public func getAuditLog(limit: Int = 50) -> String {
        AuditLog.recentEntries(limit: limit).joined(separator: "\n")
    }
}
