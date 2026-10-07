import AgentAudit
import AXorcist
import Foundation
import AppKit

extension AccessibilityService {
    // MARK: - Element Inspection

    @MainActor
    public func inspectElementAt(x: CGFloat, y: CGFloat, depth: Int = 3) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "inspectElementAt(x: \(x), y: \(y), depth: \(depth))")

        let point = CGPoint(x: x, y: y)
        if let element = Element.elementAtPoint(point) {
            return successJSON(elementProperties(element))
        }
        return errorJSON("No element found at (\(x), \(y))")
    }

    // MARK: - Get Element Properties

    @MainActor
    public func getElementProperties(role: String?, title: String?, value: String?, appBundleId: String?, x: CGFloat?, y: CGFloat?) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && x == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "getElementProperties(role: \(role ?? "nil"), title: \(title ?? "nil"), value: \(value ?? "nil"), app: \(appBundleId ?? "nil"))")

        if let x = x, let y = y {
            return inspectElementAt(x: x, y: y, depth: 2)
        }

        guard let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) else {
            return errorJSON("Element not found")
        }
        return successJSON(propertiesWithReference(found))
    }

    // MARK: - Get All Properties

    /// Get properties from an AXorcist Element directly.
    @MainActor
    public func getAllProperties(_ element: Element) -> [String: Any] {
        return elementProperties(element)
    }

    // MARK: - Open App and Get Elements

    /// Launch/activate an app and return its interactive elements in one call.
    /// This is the fastest way to discover what's clickable in an app.
    ///
    /// IMPORTANT: this MUST go through forceLaunchAndActivate() so the full
    /// pipeline runs (launch if needed, per-window unminimize, app activate,
    /// NSRunningApplication.activate fallback). The previous implementation
    /// relied on resolveBundleId() to call launchIfNeeded internally — but
    /// resolveBundleId has an early return for inputs containing a dot
    /// (literal bundle IDs), so calls like
    ///   openApp("com.apple.PhotoBooth")
    /// would COMPLETELY SKIP the unminimize step. The dock-Genied window
    /// would never come back, and the LLM would click against a still-hidden
    /// window. This was the regression the user kept hitting.
    @MainActor
    public func openApp(_ appName: String?, maxDepth: Int = 5) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        guard let appName = appName, !appName.isEmpty else {
            return errorJSON("App name required")
        }

        let bundleId = resolveBundleId(appName)
        guard let bid = bundleId else {
            return errorJSON("Could not resolve app: \(appName)")
        }

        AuditLog.log(.accessibility, "openApp(\(appName) → \(bid))")

        // Run the full launch + unminimize + activate pipeline regardless of
        // whether the input was an app name or a literal bundle ID. This is
        // the call resolveBundleId would skip for bundle-ID inputs.
        forceLaunchAndActivate(bundleId: bid)

        // Get app element AFTER the activation pipeline so we read post-unminimize state
        guard let app = RunningApplicationHelper.applications(withBundleIdentifier: bid).first,
              let appElement = Element.application(for: app) else {
            return errorJSON("Could not get app element for \(bid)")
        }

        // Collect interactive elements (buttons, text fields, etc.)
        var elements: [[String: Any]] = []
        collectInteractive(appElement, depth: maxDepth, into: &elements)

        return successJSON([
            "app": bid,
            "appName": app.localizedName ?? appName,
            "elementCount": elements.count,
            "elements": elements
        ])
    }

    /// Recursively collect interactive elements (buttons, text fields, links, etc.)
    @MainActor
    private func collectInteractive(_ element: Element, depth: Int, into results: inout [[String: Any]]) {
        guard depth > 0, results.count < 50 else { return }

        // Check if this element is interactive
        if element.isInteractive() {
            let sz = element.size()
            // Only include elements with actual size (visible on screen)
            if let sz = sz, sz.width > 0, sz.height > 0 {
                var info = elementProperties(element)
                if let name = element.computedName() { info["computedName"] = name }
                results.append(info)
            }
        }

        // Recurse into children
        if let children = element.children() {
            for child in children {
                collectInteractive(child, depth: depth - 1, into: &results)
            }
        }
    }

    // MARK: - Web Content Scanning

    @MainActor
    public func scanWebContent(appBundleId: String? = nil, maxDepth: Int = 10) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "scanWebContent(app: \(appBundleId ?? "frontmost"), depth: \(maxDepth))")

        let appElement: Element?
        if let bid = appBundleId,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bid).first {
            appElement = Element.application(for: app)
        } else if let front = RunningApplicationHelper.frontmostApplication {
            appElement = Element.application(for: front)
        } else {
            return errorJSON("No app found")
        }

        guard let root = appElement else {
            return errorJSON("Could not get app element")
        }

        // Use AXorcist to find AXWebArea elements
        let webAreas = root.searchElements(byRole: "AXWebArea")
        if webAreas.isEmpty {
            return errorJSON("No web content found. Is a browser window open?")
        }

        let interactiveRoles: Set<String> = [
            "AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
            "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider",
            "AXImage", "AXHeading", "AXStaticText", "AXGroup"
        ]

        var webElements: [[String: Any]] = []
        for webArea in webAreas {
            scanWebChildren(webArea, interactiveRoles: interactiveRoles, maxDepth: maxDepth, into: &webElements)
        }

        if webElements.isEmpty {
            return errorJSON("No web content found. Is a browser window open?")
        }
        return successJSON(["elements": webElements, "count": webElements.count])
    }

    @MainActor
    private func scanWebChildren(_ element: Element, interactiveRoles: Set<String>, maxDepth: Int, into results: inout [[String: Any]]) {
        guard maxDepth > 0, results.count < 200 else { return }

        let role = element.role() ?? ""

        if interactiveRoles.contains(role) {
            var info: [String: Any] = ["role": role]
            if let title = element.title(), !title.isEmpty { info["title"] = String(title.prefix(200)) }
            if let val = element.value() as? String, !val.isEmpty { info["value"] = String(val.prefix(200)) }
            if let desc = element.descriptionText(), !desc.isEmpty { info["description"] = String(desc.prefix(200)) }
            if let url = element.url() { info["url"] = String(url.absoluteString.prefix(500)) }
            if let ident = element.identifier(), !ident.isEmpty { info["domId"] = ident }
            if let pos = element.position() {
                info["x"] = Int(pos.x)
                info["y"] = Int(pos.y)
            }

            if role == "AXStaticText" {
                let text = (info["value"] as? String) ?? (info["title"] as? String) ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results.append(info)
                }
            } else {
                results.append(info)
            }
        }

        if let children = element.children() {
            for child in children {
                scanWebChildren(child, interactiveRoles: interactiveRoles, maxDepth: maxDepth - 1, into: &results)
            }
        }
    }
}
