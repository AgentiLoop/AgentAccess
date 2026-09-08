import AgentAudit
import AXorcist
import Foundation
import AppKit

extension AccessibilityService {
    // MARK: - Set Properties

    @MainActor
    public func setProperties(role: String?, title: String?, value: String?, appBundleId: String?, x: CGFloat?, y: CGFloat?, properties: [String: Any]) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && x == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "setProperties(role: \(role ?? "nil"), title: \(title ?? "nil"), value: \(value ?? "nil"), properties: \(properties.keys)")

        var element: Element?
        if let x = x, let y = y {
            element = Element.elementAtPoint(CGPoint(x: x, y: y))
        } else {
            element = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId)
        }

        guard let found = element else {
            return errorJSON("Element not found")
        }
        if let elRole = found.role(), Self.isRestricted(elRole) {
            return errorJSON("Cannot interact with \(elRole) — disabled in Accessibility Access")
        }

        var results: [String: Any] = [:]
        var successCount = 0

        for (key, val) in properties {
            var success = false
            if key == "AXPosition", let dict = val as? [String: CGFloat],
               let px = dict["x"], let py = dict["y"] {
                success = found.setPosition(CGPoint(x: px, y: py)) == .success
            } else if key == "AXSize", let dict = val as? [String: CGFloat],
                      let w = dict["width"], let h = dict["height"] {
                success = found.setSize(CGSize(width: w, height: h)) == .success
            } else if let s = val as? String {
                success = found.setValue(s, forAttribute: key)
            } else if let b = val as? Bool {
                success = found.setValue(b, forAttribute: key)
            } else if let i = val as? Int {
                success = found.setValue(i, forAttribute: key)
            } else {
                success = found.setValue(String(describing: val), forAttribute: key)
            }
            results[key] = success ? "set" : "failed"
            if success { successCount += 1 }
        }

        return successJSON(["message": "Set \(successCount)/\(properties.count) properties", "results": results])
    }

    // MARK: - Find Element

    @MainActor
    public func findElement(role: String?, title: String?, value: String?, appBundleId: String?, timeout: TimeInterval = elementSearchTimeout) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "findElement(role: \(role ?? "nil"), title: \(title ?? "nil"), value: \(value ?? "nil"), app: \(appBundleId ?? "nil"), timeout: \(timeout))")

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) {
                return successJSON(elementProperties(found))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return errorJSON("Element not found")
    }

    // MARK: - Get Focused Element

    @MainActor
    public func getFocusedElement(appBundleId: String? = nil) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "getFocusedElement(app: \(appBundleId ?? "nil"))")

        // Use AXorcist's Element API
        let root: Element
        if let bundleId = appBundleId,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first,
           let appEl = Element.application(for: app) {
            root = appEl
        } else {
            root = Element.systemWide()
        }

        // kAXFocusedUIElement is the canonical focus attribute — works on both
        // app elements and the system-wide element. Try it first.
        if let focused = root.focusedUIElement() {
            return successJSON(elementProperties(focused))
        }
        // Fallback: focusedApplicationElement, then its focused child
        if let focusedApp = root.focusedApplicationElement() {
            if let focusedChild = focusedApp.children()?.first(where: { $0.isFocused() == true }) {
                return successJSON(elementProperties(focusedChild))
            }
            return successJSON(elementProperties(focusedApp))
        }

        return errorJSON("No focused element found")
    }

    // MARK: - Get Children

    @MainActor
    public func getChildren(role: String?, title: String?, value: String?, appBundleId: String?, x: CGFloat?, y: CGFloat?, depth: Int = 3) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && x == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "getChildren(role: \(role ?? "nil"), title: \(title ?? "nil"), value: \(value ?? "nil"), app: \(appBundleId ?? "nil"), depth: \(depth))")

        var element: Element?
        if let x = x, let y = y {
            element = Element.elementAtPoint(CGPoint(x: x, y: y))
        } else {
            element = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId)
        }

        guard let found = element else { return errorJSON("Element not found") }
        guard let children = found.children(), !children.isEmpty else { return errorJSON("Element has no children") }

        // Recurse to `depth` levels (previously the depth parameter was ignored and
        // only direct children were returned, which made SwiftUI AXHostingView
        // subtrees look empty). Bounded by a total node cap so deep trees can't
        // produce unbounded JSON.
        var nodeCount = 0
        let maxNodes = 400
        func describe(_ el: Element, remaining: Int) -> [String: Any] {
            nodeCount += 1
            var props = elementProperties(el)
            if remaining > 1, nodeCount < maxNodes, let kids = el.children(), !kids.isEmpty {
                props["children"] = kids.prefix(maxNodes - nodeCount).map { describe($0, remaining: remaining - 1) }
            }
            return props
        }
        let results = children.map { describe($0, remaining: depth) }
        var payload: [String: Any] = ["count": results.count, "children": results]
        if nodeCount >= maxNodes { payload["truncated"] = true }
        return successJSON(payload)
    }

    // MARK: - Drag (REMOVED)
    //
    // drag(fromX:fromY:toX:toY:button:) used InputDriver to send raw CGEvents for
    // arbitrary screen-coordinate drags. Removed because:
    //   - Coordinates are unreliable across window moves and display scales
    //   - No AXorcist equivalent exists for arbitrary drags
    //   - Most legitimate drag use cases have an element-based alternative:
    //       * Window move/resize  → setWindowFrame(appBundleId:x:y:width:height:)
    //       * Slider value        → set_properties on AXSlider with new AXValue
    //       * List reorder        → typically driven by menu items or buttons
    //   - The few drags that have no AX equivalent (file-system drag-and-drop
    //     between Finder and another app) just don't work via AX and should be
    //     done with a Shortcut or AppleScript instead.

    // MARK: - Wait For Element

    @MainActor
    public func waitForElement(role: String?, title: String?, value: String?, appBundleId: String?, timeout: TimeInterval = elementSearchTimeout, pollInterval: TimeInterval = 0.5) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "waitForElement(role: \(role ?? "nil"), title: \(title ?? "nil"), value: \(value ?? "nil"), app: \(appBundleId ?? "nil"), timeout: \(timeout))")

        let startTime = Date()
        var attempts = 0
        while Date().timeIntervalSince(startTime) < timeout {
            attempts += 1
            if let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) {
                let elapsed = Date().timeIntervalSince(startTime)
                return successJSON(["message": "Element found", "attempts": attempts, "elapsed": String(format: "%.2f", elapsed), "properties": elementProperties(found)])
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return errorJSON("Element not found within \(timeout)s timeout after \(attempts) attempts")
    }

    // MARK: - Show Menu

    /// Show the context menu (or any AXShowMenu-supported menu) on an element
    /// identified by role/title/value/appBundleId. AXorcist-only — no coordinate
    /// fallback. If the element doesn't support AXShowMenu, the call returns an
    /// error and the LLM should look for a different actionable element.
    @MainActor
    public func showMenu(role: String?, title: String?, value: String?, appBundleId: String?, x: CGFloat?, y: CGFloat?) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        // x/y kept in signature for source compatibility but ignored — coordinates are
        // not a supported way to identify elements in this API.
        _ = x; _ = y
        AuditLog.log(.accessibility, "showMenu(role: \(role ?? "nil"), title: \(title ?? "nil"))")

        guard let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) else {
            return errorJSON("Element not found. Provide role/title/value to identify the element — coordinate lookup is not supported.")
        }
        if let elRole = found.role(), Self.isRestricted(elRole) {
            return errorJSON("Cannot interact with \(elRole) — disabled in Accessibility Access")
        }

        if found.isActionSupported(AXAction.showMenu.rawValue) {
            do {
                try found.performAction(.showMenu)
                return successJSON(["message": "Menu shown"])
            } catch {
                return errorJSON("AXShowMenu failed: \(error.localizedDescription)")
            }
        }
        return errorJSON("Element does not support AXShowMenu. Try a different element, or use clickMenuItem to invoke a known menu path.")
    }

    // MARK: - Smart Element Click (AXorcist command system)

    @MainActor
    public func clickElement(role: String?, title: String?, value: String?, appBundleId: String?, timeout: TimeInterval = elementSearchTimeout, verify: Bool = false) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        // Resolve app name → bundle ID
        let appBundleId = resolveBundleId(appBundleId)

        AuditLog.log(.accessibility, "clickElement(role: \(role ?? "nil"), title: \(title ?? "nil"), value: \(value ?? "nil"), app: \(appBundleId ?? "nil"), timeout: \(timeout))")

        if role == nil && title == nil && value == nil {
            return errorJSON("No search criteria provided")
        }

        // Step 1: Get the app element via AXorcist
        let appElement: Element?
        if let bundleId = appBundleId,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first {
            appElement = Element.application(for: app)
            // Activate app so it's frontmost
            _ = appElement?.activate()
        } else {
            appElement = Element.focusedApplication()
        }

        guard let root = appElement else {
            return errorJSON("Could not get app element for \(appBundleId ?? "frontmost")")
        }

        // Step 2: Search with exponential backoff (0.1s → 0.2s → 0.4s → 0.8s → 1.0s max)
        var found: Element?
        let startTime = Date()
        var retryDelay: TimeInterval = 0.1
        while Date().timeIntervalSince(startTime) < timeout {
            let results = root.findElements(role: role, title: title, label: nil, value: value, identifier: nil, maxDepth: 20)
            if let match = results.first(where: { ($0.size()?.width ?? 0) > 0 }) ?? results.first {
                found = match
                break
            }
            // Fallback: fuzzy search by title across description/help/placeholder
            if let title = title {
                var options = ElementSearchOptions()
                options.maxDepth = 20
                options.caseInsensitive = true
                if let role = role { options.includeRoles = [role] }
                if let match = root.findElement(matching: title, options: options) {
                    found = match
                    break
                }
            }
            Thread.sleep(forTimeInterval: retryDelay)
            retryDelay = min(retryDelay * 2, 1.0)
        }

        guard let element = found else {
            // Dead-end errors waste an LLM turn. List the titles that actually
            // exist for the requested role so the model can retry correctly.
            let hints = interactiveTitles(in: root, role: role)
            var err = "Element not found in \(appBundleId ?? "frontmost app"): role=\(role ?? "any"), title=\(title ?? "any")."
            if !hints.isEmpty {
                err += " Available \(role ?? "interactive") elements: \(hints.joined(separator: " | "))"
            }
            return errorJSON(err)
        }

        // Step 3: Wait for element to be enabled
        let enableStart = Date()
        while element.isEnabled() == false, Date().timeIntervalSince(enableStart) < 5.0 {
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Step 4: Click via AXorcist — Element.click() first (centers in frame),
        // then AXPress as a fallback for menu items and other AXPress-only elements.
        // No coordinate-based fallback: if both AXorcist paths fail, the element is
        // genuinely not clickable through accessibility, and a raw mouse event would
        // just produce the wrong result anyway.
        do {
            try element.click()
            return successJSON(["message": "Clicked element", "element": elementProperties(element)])
        } catch {
            do {
                try element.performAction(.press)
                return successJSON(["message": "Pressed element", "element": elementProperties(element)])
            } catch {
                return errorJSON("Element is not clickable through accessibility (Element.click and AXPress both failed) for \(element.role() ?? "unknown") '\(element.title() ?? "")'. Verify the element is enabled and visible, or look for a different actionable element nearby.")
            }
        }
    }

    // MARK: - Adaptive Wait for Element

    @MainActor
    public func waitForElementAdaptive(
        role: String?, title: String?, value: String?, appBundleId: String?,
        timeout: TimeInterval = elementSearchTimeout,
        initialDelay: TimeInterval = 0.1,
        maxDelay: TimeInterval = automationMaxDelay,
        multiplier: Double = 1.5
    ) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "waitForElementAdaptive(role: \(role ?? "nil"), title: \(title ?? "nil"), value: \(value ?? "nil"), app: \(appBundleId ?? "nil"), timeout: \(timeout))")

        let startTime = Date()
        var currentDelay = initialDelay
        var attempts = 0
        while Date().timeIntervalSince(startTime) < timeout {
            attempts += 1
            if let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) {
                let elapsed = Date().timeIntervalSince(startTime)
                var props = elementProperties(found)
                props["found_after_attempts"] = attempts
                props["elapsed_seconds"] = String(format: "%.2f", elapsed)
                return successJSON(props)
            }
            Thread.sleep(forTimeInterval: currentDelay)
            currentDelay = min(currentDelay * multiplier, maxDelay)
        }
        return errorJSON("Element not found within \(timeout)s timeout after \(attempts) attempts (adaptive polling)")
    }

    // MARK: - Verification Helpers

    @MainActor
    public func captureVerificationScreenshot(action: String, role: String?, title: String?, appBundleId: String?) async -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        let screenshotResult = await captureAllWindows()
        var elementStatus = "not_verified"
        if (role ?? title) != nil {
            let findResult = findElement(role: role, title: title, value: nil, appBundleId: appBundleId, timeout: 1.0)
            elementStatus = Self.isSuccessJSON(findResult) ? "verified_present" : "not_found_after_action"
        }
        return successJSON(["action": action, "element_status": elementStatus, "screenshot": screenshotResult])
    }

    // MARK: - Type Text Into Element (AXorcist Element.typeText)

    @MainActor
    public func typeTextIntoElement(role: String?, title: String?, text: String, appBundleId: String?, verify: Bool = true) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "typeTextIntoElement(role: \(role ?? "nil"), title: \(title ?? "nil"), text: \(text.count) chars)")

        guard let found = findAXElement(role: role, title: title, value: nil, appBundleId: appBundleId) else {
            // List the text inputs that actually exist so the LLM can retry
            // with a real title instead of guessing again.
            var hints: [String] = []
            if let bid = appBundleId,
               let app = RunningApplicationHelper.applications(withBundleIdentifier: bid).first,
               let appElement = Element.application(for: app) {
                for r in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"] {
                    hints += interactiveTitles(in: appElement, role: r, limit: 8).map { "\(r) '\($0)'" }
                }
            }
            var err = "Element not found for typing (role=\(role ?? "any"), title=\(title ?? "any"))."
            if !hints.isEmpty { err += " Text inputs present: \(hints.joined(separator: " | "))" }
            return errorJSON(err)
        }

        // AXorcist: try Element.setValue first (fastest)
        if found.setValue(text, forAttribute: "AXValue") {
            return successJSON(["message": "Text set via AXValue", "method": "element_setValue", "text_length": text.count])
        }

        // AXorcist: fallback to Element.typeText with clearFirst via Element.clearField()
        do {
            try found.typeText(text, clearFirst: true)
            return successJSON(["message": "Typed \(text.count) characters", "method": "element_typeText", "text_length": text.count])
        } catch {
            return errorJSON("Type failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Legacy Compatibility (return AXorcist Element.underlyingElement)

    /// Find element in app — returns AXorcist Element
    @MainActor
    public func findElementInApp(pid: pid_t, role: String?, title: String?, value: String?) -> Element? {
        guard let appElement = Element.application(for: pid) else { return nil }
        return searchInElement(appElement, role: role, title: title, value: value)
    }

    /// Find element globally — returns AXorcist Element
    @MainActor
    public func findElementGlobally(role: String?, title: String?, value: String?) -> Element? {
        return findAXElement(role: role, title: title, value: value, appBundleId: nil)
    }

    // MARK: - Failure Hints

    /// Collect visible names for elements of `role` (or any interactive element
    /// when role is nil) inside `root`. Used by failure paths so "not found"
    /// errors teach the LLM the app's real vocabulary instead of dead-ending.
    @MainActor
    func interactiveTitles(in root: Element, role: String?, limit: Int = 25) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func collect(_ el: Element, depth: Int) {
            guard depth > 0, names.count < limit else { return }
            let matches = role == nil ? el.isInteractive() : (el.role() == role)
            if matches {
                let name = el.title().flatMap { $0.isEmpty ? nil : $0 }
                    ?? el.descriptionText().flatMap { $0.isEmpty ? nil : $0 }
                    ?? el.computedName()
                if let n = name, !n.isEmpty, seen.insert(n).inserted {
                    names.append(String(n.prefix(60)))
                }
            }
            if let children = el.children() {
                for c in children where names.count < limit {
                    collect(c, depth: depth - 1)
                }
            }
        }
        collect(root, depth: 15)
        return names
    }
}
