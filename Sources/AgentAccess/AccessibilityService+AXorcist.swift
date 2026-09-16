import AgentAudit
import AXorcist
import Foundation
import AppKit

// MARK: - Full AXorcist Command System Integration

extension AccessibilityService {

    // MARK: - Run Command (full AXorcist command envelope)

    /// Execute any AXorcist command via the command envelope system.
    /// Supports: query, performAction, getAttributes, describeElement, extractText,
    /// setFocusedValue, getElementAtPoint, getFocusedElement, observe, collectAll, batch.
    @MainActor
    public func runCommand(_ envelope: AXCommandEnvelope) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "runCommand(\(envelope.command.type), id: \(envelope.commandID))")

        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Query Command

    /// Find elements using AXorcist's full query system with Locator/Criterion matching.
    @MainActor
    public func queryElements(
        appIdentifier: String? = nil,
        criteria: [(attribute: String, value: String, matchType: String?)] = [],
        matchAll: Bool = true,
        attributes: [String]? = nil,
        maxDepth: Int = 10
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "queryElements(app: \(appIdentifier ?? "focused"), criteria: \(criteria.count), matchAll: \(matchAll))")

        let axCriteria = criteria.map { c in
            Criterion(attribute: c.attribute, value: c.value, matchType: parseMatchType(c.matchType))
        }
        let locator = Locator(matchAll: matchAll, criteria: axCriteria)
        let cmd = QueryCommand(appIdentifier: appIdentifier, locator: locator, attributesToReturn: attributes, maxDepthForSearch: maxDepth)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .query(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Perform Action via Command System

    /// Perform an action on an element found by AXorcist locator criteria.
    @MainActor
    public func performActionByLocator(
        appIdentifier: String? = nil,
        criteria: [(attribute: String, value: String, matchType: String?)] = [],
        action: String,
        value: String? = nil,
        maxDepth: Int = 10
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "performActionByLocator(app: \(appIdentifier ?? "focused"), action: \(action))")

        if Self.isRestricted(action) {
            return errorJSON("Action '\(action)' is disabled in Accessibility Settings.")
        }

        let axCriteria = criteria.map { c in
            Criterion(attribute: c.attribute, value: c.value, matchType: parseMatchType(c.matchType))
        }
        let locator = Locator(matchAll: true, criteria: axCriteria)
        let actionValue: AnyCodable? = value != nil ? AnyCodable(value!) : nil
        let cmd = PerformActionCommand(appIdentifier: appIdentifier, locator: locator, action: action, value: actionValue, maxDepthForSearch: maxDepth)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .performAction(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Get Attributes via Command System

    /// Get specific attributes from an element found by locator.
    @MainActor
    public func getAttributesByLocator(
        appIdentifier: String? = nil,
        criteria: [(attribute: String, value: String, matchType: String?)] = [],
        attributes: [String],
        maxDepth: Int = 10
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "getAttributesByLocator(app: \(appIdentifier ?? "focused"), attrs: \(attributes))")

        let axCriteria = criteria.map { c in
            Criterion(attribute: c.attribute, value: c.value, matchType: parseMatchType(c.matchType))
        }
        let locator = Locator(matchAll: true, criteria: axCriteria)
        let cmd = GetAttributesCommand(appIdentifier: appIdentifier, locator: locator, attributes: attributes, maxDepthForSearch: maxDepth)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .getAttributes(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Describe Element

    /// Get a detailed description of an element's structure and properties.
    @MainActor
    public func describeElement(
        appIdentifier: String? = nil,
        criteria: [(attribute: String, value: String, matchType: String?)] = [],
        depth: Int = 3,
        includeIgnored: Bool = false,
        maxDepth: Int = 10
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "describeElement(app: \(appIdentifier ?? "focused"), depth: \(depth))")

        let axCriteria = criteria.map { c in
            Criterion(attribute: c.attribute, value: c.value, matchType: parseMatchType(c.matchType))
        }
        let locator = Locator(matchAll: true, criteria: axCriteria)
        let cmd = DescribeElementCommand(appIdentifier: appIdentifier, locator: locator, maxDepthForSearch: maxDepth, depth: depth, includeIgnored: includeIgnored)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .describeElement(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Extract Text

    /// Extract text content from an element and its descendants.
    @MainActor
    public func extractText(
        appIdentifier: String? = nil,
        criteria: [(attribute: String, value: String, matchType: String?)] = [],
        includeChildren: Bool = true,
        maxDepth: Int = 5
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "extractText(app: \(appIdentifier ?? "focused"))")

        let axCriteria = criteria.map { c in
            Criterion(attribute: c.attribute, value: c.value, matchType: parseMatchType(c.matchType))
        }
        let locator = Locator(matchAll: true, criteria: axCriteria)
        let cmd = ExtractTextCommand(appIdentifier: appIdentifier, locator: locator, includeChildren: includeChildren, maxDepth: maxDepth)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .extractText(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Set Focused Value

    /// Set the value of the currently focused element.
    @MainActor
    public func setFocusedValue(
        appIdentifier: String? = nil,
        criteria: [(attribute: String, value: String, matchType: String?)] = [],
        value: String
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "setFocusedValue(app: \(appIdentifier ?? "focused"), value: \(value.prefix(50)))")

        let axCriteria = criteria.map { c in
            Criterion(attribute: c.attribute, value: c.value, matchType: parseMatchType(c.matchType))
        }
        let locator = Locator(matchAll: true, criteria: axCriteria)
        let cmd = SetFocusedValueCommand(appIdentifier: appIdentifier, locator: locator, value: value)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .setFocusedValue(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Get Element at Point via Command System

    /// Find the element at specific screen coordinates using AXorcist command system.
    @MainActor
    public func getElementAtPoint(
        x: Float, y: Float,
        appIdentifier: String? = nil,
        attributes: [String]? = nil
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "getElementAtPoint(x: \(x), y: \(y), app: \(appIdentifier ?? "any"))")

        let cmd = GetElementAtPointCommand(appIdentifier: appIdentifier, x: x, y: y, attributesToReturn: attributes)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .getElementAtPoint(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Get Focused Element via Command System

    /// Get the currently focused element using AXorcist command system.
    @MainActor
    public func getFocusedElementCommand(
        appIdentifier: String? = nil,
        attributes: [String]? = nil
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "getFocusedElementCommand(app: \(appIdentifier ?? "focused"))")

        let cmd = GetFocusedElementCommand(appIdentifier: appIdentifier, attributesToReturn: attributes)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .getFocusedElement(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Collect All Elements

    /// Recursively collect all elements from an app with optional filtering.
    @MainActor
    public func collectAllElements(
        appIdentifier: String? = nil,
        attributes: [String]? = nil,
        maxDepth: Int = 10,
        filterCriteria: [String: String]? = nil
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "collectAllElements(app: \(appIdentifier ?? "focused"), maxDepth: \(maxDepth))")

        let cmd = CollectAllCommand(appIdentifier: appIdentifier, attributesToReturn: attributes, maxDepth: maxDepth, filterCriteria: filterCriteria)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .collectAll(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Batch Commands

    /// Execute multiple AXorcist commands in sequence.
    @MainActor
    public func batchCommands(_ commands: [AXCommandEnvelope]) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "batchCommands(count: \(commands.count))")

        let subCommands = commands.map { AXBatchCommand.SubCommandEnvelope(commandID: $0.commandID, command: $0.command) }
        let batch = AXBatchCommand(commands: subCommands)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .batch(batch))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Observe Notifications

    /// Start observing accessibility notifications on an element.
    @MainActor
    public func observeNotifications(
        appIdentifier: String? = nil,
        criteria: [(attribute: String, value: String, matchType: String?)]? = nil,
        notifications: [String],
        notificationName: String = "AXValueChanged",
        includeDetails: Bool = true,
        watchChildren: Bool = false
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "observeNotifications(app: \(appIdentifier ?? "focused"), notifications: \(notifications))")

        let axCriteria = criteria?.map { c in
            Criterion(attribute: c.attribute, value: c.value, matchType: parseMatchType(c.matchType))
        }
        let locator: Locator? = axCriteria.map { Locator(matchAll: true, criteria: $0) }
        guard let axNotification = AXNotification(rawValue: notificationName) ?? AXNotification(rawValue: "AXValueChanged") else {
            return errorJSON("Invalid notification name: \(notificationName)")
        }
        let cmd = ObserveCommand(
            appIdentifier: appIdentifier,
            locator: locator,
            notifications: notifications,
            includeDetails: includeDetails,
            watchChildren: watchChildren,
            notificationName: axNotification
        )
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .observe(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - Text Extraction (Direct Element API)

    /// Extract text from an element using AXorcist's extractTextFromElement utility.
    @MainActor
    public func extractTextDirect(role: String?, title: String?, value: String?, appBundleId: String?, maxDepth: Int = 5) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "extractTextDirect(role: \(role ?? "nil"), title: \(title ?? "nil"))")

        guard let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) else {
            return errorJSON("Element not found")
        }

        if let text = extractTextFromElement(found, maxDepth: maxDepth) {
            return successJSON(["text": text, "length": text.count])
        }
        return errorJSON("No text content found in element")
    }

    // MARK: - Window Operations (AXorcist Element API)

    /// Minimize a window by app bundle ID.
    @MainActor
    public func minimizeWindow(appBundleId: String?) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        guard let window = findAppWindow(appBundleId: appBundleId) else {
            return errorJSON("No window found")
        }
        return window.minimizeWindow() ? successJSON(["message": "Window minimized"]) : errorJSON("Failed to minimize window")
    }

    /// Unminimize a window by app bundle ID.
    @MainActor
    public func unminimizeWindow(appBundleId: String?) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        guard let window = findAppWindow(appBundleId: appBundleId) else {
            return errorJSON("No window found")
        }
        return window.unminimizeWindow() ? successJSON(["message": "Window unminimized"]) : errorJSON("Failed to unminimize window")
    }

    /// Maximize a window by app bundle ID.
    @MainActor
    public func maximizeWindow(appBundleId: String?) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        guard let window = findAppWindow(appBundleId: appBundleId) else {
            return errorJSON("No window found")
        }
        return window.maximizeWindow() ? successJSON(["message": "Window maximized"]) : errorJSON("Failed to maximize window")
    }

    // MARK: - Element Click via AXorcist

    /// Click an element directly using AXorcist's Element.click() method.
    @MainActor
    public func clickElementDirect(role: String?, title: String?, value: String?, appBundleId: String?, button: String = "left", clickCount: Int = 1) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        guard let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) else {
            return errorJSON("Element not found")
        }
        if let elRole = found.role(), Self.isRestricted(elRole) {
            return errorJSON("Cannot interact with \(elRole) — disabled in Accessibility Access")
        }
        let mouseButton: MouseButton = button == "right" ? .right : .left
        do {
            try found.click(button: mouseButton, clickCount: clickCount)
            return successJSON(["message": "Clicked element", "role": found.role() ?? "Unknown", "title": found.title() ?? ""])
        } catch {
            return errorJSON("Click failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Type Into Element via AXorcist

    /// Type text into an element using AXorcist's Element.typeText() method.
    @MainActor
    public func typeIntoElementDirect(role: String?, title: String?, value: String?, appBundleId: String?, text: String, clearFirst: Bool = false) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        guard let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) else {
            return errorJSON("Element not found")
        }
        do {
            try found.typeText(text, clearFirst: clearFirst)
            return successJSON(["message": "Typed \(text.count) characters", "clearFirst": clearFirst])
        } catch {
            return errorJSON("Type failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Scroll Element via AXorcist

    /// Scroll an element using AXorcist's Element.scroll() method.
    @MainActor
    public func scrollElementDirect(role: String?, title: String?, value: String?, appBundleId: String?, direction: String, amount: Int = 3) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        guard let found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId) else {
            return errorJSON("Element not found")
        }
        let scrollDir: ScrollDirection
        switch direction.lowercased() {
        case "up": scrollDir = .up
        case "down": scrollDir = .down
        case "left": scrollDir = .left
        case "right": scrollDir = .right
        default: scrollDir = .down
        }
        do {
            try found.scroll(direction: scrollDir, amount: amount)
            return successJSON(["message": "Scrolled \(direction) by \(amount)"])
        } catch {
            return errorJSON("Scroll failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Wait Until Actionable

    /// Wait for an element to become actionable (enabled, visible, on screen).
    /// Polls for the element until it appears, then uses AXorcist's
    /// `Element.waitUntilActionable(timeout:pollInterval:)` for the remaining time.
    @MainActor
    public func waitUntilActionable(role: String?, title: String?, value: String?, appBundleId: String?, timeout: TimeInterval = 5.0, pollInterval: TimeInterval = 0.1) async -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "waitUntilActionable(role: \(role ?? "nil"), title: \(title ?? "nil"), app: \(appBundleId ?? "nil"), timeout: \(timeout))")

        let start = Date()
        var found: Element?
        while found == nil, Date().timeIntervalSince(start) < timeout {
            found = findAXElement(role: role, title: title, value: value, appBundleId: appBundleId)
            if found == nil {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
        guard let element = found else {
            return errorJSON("Element not found within \(timeout)s")
        }
        let remaining = max(timeout - Date().timeIntervalSince(start), pollInterval)
        do {
            let ready = try await element.waitUntilActionable(timeout: remaining, pollInterval: pollInterval)
            return successJSON([
                "message": "Element is actionable",
                "waited": Date().timeIntervalSince(start),
                "properties": elementProperties(ready)
            ])
        } catch {
            return errorJSON("Element is not actionable after \(timeout)s (disabled, hidden, or off-screen)")
        }
    }

    // MARK: - Select Text Range

    /// Set the selected text range on a text element using AXorcist's typed
    /// `Element.setSelectedTextRange(_:)` setter (AXorcist 0.1.7+).
    @MainActor
    public func selectTextRange(role: String?, title: String?, value: String?, appBundleId: String?, location: Int, length: Int) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        guard location >= 0, length >= 0 else {
            return errorJSON("location and length must be >= 0")
        }
        AuditLog.log(.accessibility, "selectTextRange(role: \(role ?? "nil"), title: \(title ?? "nil"), app: \(appBundleId ?? "nil"), location: \(location), length: \(length))")

        guard let found = findAXElement(role: role ?? "AXTextField", title: title, value: value, appBundleId: appBundleId)
                ?? (role == nil ? findAXElement(role: "AXTextArea", title: title, value: value, appBundleId: appBundleId) : nil) else {
            return errorJSON("Element not found")
        }
        let err = found.setSelectedTextRange(CFRange(location: location, length: length))
        guard err == .success else {
            return errorJSON("setSelectedTextRange failed: \(err)")
        }
        var result: [String: Any] = ["message": "Selected range", "location": location, "length": length]
        if let range = found.selectedTextRange() {
            result["selectedTextRange"] = ["location": range.location, "length": range.length]
        }
        if let text = found.selectedText() { result["selectedText"] = text }
        return successJSON(result)
    }


    // MARK: - AXorcist Logs

    /// Get AXorcist's internal debug logs.
    @MainActor
    public func getAXorcistLogs() -> String {
        let logs = AXorcist.shared.getLogs()
        return successJSON(["logs": logs, "count": logs.count])
    }

    /// Clear AXorcist's internal debug logs.
    @MainActor
    public func clearAXorcistLogs() -> String {
        AXorcist.shared.clearLogs()
        return successJSON(["message": "AXorcist logs cleared"])
    }

    // MARK: - Path-Based Navigation

    /// Query elements using path-based navigation through the UI hierarchy.
    @MainActor
    public func queryWithPath(
        appIdentifier: String? = nil,
        pathFromRoot: [[String: String]],
        criteria: [(attribute: String, value: String, matchType: String?)] = [],
        attributes: [String]? = nil,
        maxDepth: Int = 10
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "queryWithPath(app: \(appIdentifier ?? "focused"), pathSteps: \(pathFromRoot.count))")

        let pathHints = pathFromRoot.map { step in
            JSONPathHintComponent(
                attribute: step["attribute"] ?? "AXRole",
                value: step["value"] ?? "",
                depth: Int(step["depth"] ?? "3") ?? 3,
                matchType: parseMatchType(step["match_type"])
            )
        }
        let axCriteria = criteria.map { c in
            Criterion(attribute: c.attribute, value: c.value, matchType: parseMatchType(c.matchType))
        }
        let locator = Locator(matchAll: true, criteria: axCriteria, rootElementPathHint: pathHints)
        let cmd = QueryCommand(appIdentifier: appIdentifier, locator: locator, attributesToReturn: attributes, maxDepthForSearch: maxDepth)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .query(cmd))
        let response = AXorcist.shared.runCommand(envelope)
        return axResponseToJSON(response)
    }

    // MARK: - App at Point (AXorcist AppLocator)

    /// Find the app under a screen coordinate using AXorcist's AppLocator.
    @MainActor
    public func appAtPoint(x: CGFloat, y: CGFloat) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        if let app = AppLocator.app(at: CGPoint(x: x, y: y)) {
            return successJSON([
                "name": app.localizedName ?? "Unknown",
                "bundleId": app.bundleIdentifier ?? "unknown",
                "pid": Int(app.processIdentifier)
            ])
        }
        return errorJSON("No app found at (\(x), \(y))")
    }

    // MARK: - Helpers

    @MainActor
    private func findAppWindow(appBundleId: String?) -> Element? {
        let appElement: Element?
        if let bundleId = appBundleId,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first {
            appElement = Element.application(for: app)
        } else if let app = RunningApplicationHelper.frontmostApplication {
            appElement = Element.application(for: app)
        } else {
            return nil
        }
        guard let root = appElement, let appWindows = root.windows() else { return nil }
        return appWindows.first(where: { $0.role() == "AXWindow" })
    }

    private func parseMatchType(_ str: String?) -> JSONPathHintComponent.MatchType? {
        guard let s = str else { return nil }
        switch s.lowercased() {
        case "exact": return .exact
        case "contains": return .contains
        case "regex": return .regex
        case "prefix": return .prefix
        case "suffix": return .suffix
        case "containsany": return .containsAny
        default: return nil
        }
    }

    @MainActor
    private func axResponseToJSON(_ response: AXResponse) -> String {
        switch response {
        case .success(let payload, let logs):
            var result: [String: Any] = ["success": true]
            if let payload = payload {
                // Try to encode payload to JSON-compatible form
                if let encoded = try? JSONEncoder().encode(payload),
                   let dict = try? JSONSerialization.jsonObject(with: encoded) {
                    result["data"] = dict
                } else {
                    result["data"] = String(describing: payload.value)
                }
            }
            if let logs = logs, !logs.isEmpty { result["logs"] = logs }
            if let d = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
               let s = String(data: d, encoding: .utf8) { return s }
            return "{\"success\": true}"
        case .error(let message, let code, let logs):
            var result: [String: Any] = ["success": false, "error": message, "errorCode": code.rawValue]
            if let logs = logs, !logs.isEmpty { result["logs"] = logs }
            if let d = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
               let s = String(data: d, encoding: .utf8) { return s }
            return errorJSON(message)
        }
    }
}
