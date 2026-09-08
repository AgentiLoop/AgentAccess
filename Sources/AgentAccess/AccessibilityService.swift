import AgentAudit
import AXorcist
import Foundation
import AppKit

/// Accessibility automation service for interacting with UI elements via AXorcist.
/// Provides tools for window listing, element inspection, and UI interaction.
public final class AccessibilityService: @unchecked Sendable {
    public static let shared = AccessibilityService()

    // MARK: - Browser Detection

    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    public static func isBrowser(_ bundleId: String?) -> Bool {
        guard let bid = bundleId else { return false }
        return browserBundleIDs.contains(bid)
    }

    @MainActor
    public static func frontmostAppIsBrowser() -> Bool {
        guard let bid = RunningApplicationHelper.frontmostApplication?.bundleIdentifier else { return false }
        return browserBundleIDs.contains(bid)
    }

    public static func safariPageInfo() -> String {
        return "Error: Safari/browser detected. Do not use accessibility for web pages. Use the web tool: web(action: \"scan\") to find inputs/buttons, web(action: \"open\", url: \"...\"), web(action: \"type\", selector: \"...\", text: \"...\"), web(action: \"click\", selector: \"...\"), web(action: \"read_content\")."
    }

    // MARK: - Window Listing

    @MainActor
    public func listWindows(limit: Int = 50, appBundleId: String? = nil) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        let resolvedApp = resolveBundleId(appBundleId)
        AuditLog.log(.accessibility, "listWindows(limit: \(limit), app: \(resolvedApp ?? "all"))")

        // If app specified, use AXorcist to get just that app's windows
        if let bundleId = resolvedApp,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first,
           let appElement = Element.application(for: app),
           let appWindows = appElement.windows() {
            // CG window list for the same pid — used to attach windowId so the
            // output can drive screenshot(windowId:) / getWindowFrame(windowId:).
            let cgWindows = WindowInfoHelper.getWindows(for: app.processIdentifier) ?? []
            var usedWindowIds = Set<Int>()
            var results: [[String: Any]] = []
            for window in appWindows.prefix(limit) {
                var info: [String: Any] = [:]
                info["ownerName"] = app.localizedName ?? bundleId
                info["ownerPID"] = Int(app.processIdentifier)
                if let title = window.title() { info["windowName"] = title }
                if let frame = window.frame() {
                    info["bounds"] = ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height]
                }
                if let role = window.role() { info["role"] = role }
                // Match the AX window to its CG window: prefer title match,
                // fall back to frame match. Each CG id is used at most once.
                let axTitle = window.title() ?? ""
                let axFrame = window.frame()
                for cg in cgWindows {
                    guard let cgId = cg[CFConstants.cgWindowNumber] as? Int,
                          !usedWindowIds.contains(cgId),
                          let layer = cg[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
                    let cgName = cg[CFConstants.cgWindowName] as? String ?? ""
                    var matches = !axTitle.isEmpty && cgName == axTitle
                    if !matches, let f = axFrame, let b = cg[CFConstants.cgWindowBounds] as? [String: CGFloat] {
                        matches = abs((b["X"] ?? -1) - f.origin.x) < 2 && abs((b["Y"] ?? -1) - f.origin.y) < 2
                            && abs((b["Width"] ?? -1) - f.width) < 2 && abs((b["Height"] ?? -1) - f.height) < 2
                    }
                    if matches {
                        info["windowId"] = cgId
                        usedWindowIds.insert(cgId)
                        break
                    }
                }
                results.append(info)
            }
            return successJSON(["windows": results, "count": results.count, "app": bundleId])
        }

        let windows = WindowInfoHelper.getVisibleWindows() ?? []

        var results: [[String: Any]] = []
        for (index, window) in windows.enumerated() {
            guard index < limit else { break }
            guard let windowID = window[CFConstants.cgWindowNumber] as? Int,
                  let ownerPID = window[CFConstants.cgWindowOwnerPID] as? Int32,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }  // Only app windows (skip Control Center, menubar, etc.)

            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = window[CFConstants.cgWindowName] as? String ?? ""
            let appName = getProcessName(pid: ownerPID) ?? ownerName

            var windowInfo: [String: Any] = [:]
            windowInfo["windowId"] = windowID
            windowInfo["ownerName"] = appName
            windowInfo["windowName"] = windowName

            var boundsInfo: [String: CGFloat] = [:]
            if let bounds = window[CFConstants.cgWindowBounds] as? [String: CGFloat] {
                boundsInfo["x"] = bounds["X"] ?? 0
                boundsInfo["y"] = bounds["Y"] ?? 0
                boundsInfo["width"] = bounds["Width"] ?? 0
                boundsInfo["height"] = bounds["Height"] ?? 0
            }
            windowInfo["bounds"] = boundsInfo

            results.append(windowInfo)
        }

        let response: [String: Any] = ["windows": results, "count": results.count]
        return successJSON(response)
    }

    // MARK: - AXorcist Helpers

    /// Build an AXorcist Locator from role/title/value/description criteria with flexible matching.
    @MainActor
    public func buildLocator(role: String? = nil, title: String? = nil, value: String? = nil, description: String? = nil, identifier: String? = nil) -> Locator {
        var criteria: [Criterion] = []
        if let role = role {
            criteria.append(Criterion(attribute: "AXRole", value: role))
        }
        if let title = title {
            criteria.append(Criterion(attribute: "AXTitle", value: title, matchType: .contains))
        }
        if let value = value {
            criteria.append(Criterion(attribute: "AXValue", value: value, matchType: .contains))
        }
        if let description = description {
            criteria.append(Criterion(attribute: "AXDescription", value: description, matchType: .contains))
        }
        if let identifier = identifier {
            criteria.append(Criterion(attribute: "AXIdentifier", value: identifier))
        }
        return Locator(matchAll: true, criteria: criteria)
    }

    /// Find an AXorcist Element using role/title/value in a specific app or globally.
    @MainActor
    public func findAXElement(role: String?, title: String?, value: String?, appBundleId: String?) -> Element? {
        // Resolve app name → bundle ID
        let appBundleId = resolveBundleId(appBundleId)
        if let bundleId = appBundleId {
            guard let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first,
                  let appElement = Element.application(for: app) else { return nil }
            return searchInElement(appElement, role: role, title: title, value: value)
        } else if let frontApp = RunningApplicationHelper.frontmostApplication,
                  let appElement = Element.application(for: frontApp) {
            return searchInElement(appElement, role: role, title: title, value: value)
        }
        // Global search across all running apps
        for app in RunningApplicationHelper.filteredApplications(options: .init(excludeProhibitedApps: true)) {
            guard app.activationPolicy == .regular,
                  let appElement = Element.application(for: app) else { continue }
            if let found = searchInElement(appElement, role: role, title: title, value: value) {
                return found
            }
        }
        return nil
    }

    /// Search within an Element hierarchy using AXorcist's flexible matching.
    @MainActor
    func searchInElement(_ root: Element, role: String?, title: String?, value: String?) -> Element? {
        // Use AXorcist's findElements for multi-criteria search
        let results = root.findElements(
            role: role,
            title: title,
            label: nil,
            value: value,
            identifier: nil,
            maxDepth: 100
        )
        // If title search by exact match failed, try description-based search
        if results.isEmpty, let title = title {
            // Fall back to AXorcist's string-based search which checks description, help, etc.
            var options = ElementSearchOptions()
            options.maxDepth = 100
            options.caseInsensitive = true
            if let role = role {
                options.includeRoles = [role]
            }
            return root.findElement(matching: title, options: options)
        }
        return results.first
    }

    /// Convert an AXorcist Element's properties to a dictionary for JSON output.
    /// Uses standard AX* key names that LLMs recognize from training data.
    @MainActor
    public func elementProperties(_ element: Element) -> [String: Any] {
        var result: [String: Any] = [:]
        if let role = element.role() { result["AXRole"] = role }
        if let title = element.title() { result["AXTitle"] = title }
        if let desc = element.descriptionText() { result["AXDescription"] = desc }
        if let roleDesc = element.roleDescription() { result["AXRoleDescription"] = roleDesc }
        if let sub = element.subrole() { result["AXSubrole"] = sub }
        if let ident = element.identifier() { result["AXIdentifier"] = ident }
        if let help = element.help() { result["AXHelp"] = help }
        if let enabled = element.isEnabled() { result["AXEnabled"] = enabled }
        if let focused = element.isFocused() { result["AXFocused"] = focused }
        if let hidden = element.isHidden() { result["AXHidden"] = hidden }
        if let pos = element.position() { result["AXPosition"] = ["x": pos.x, "y": pos.y] }
        if let sz = element.size() { result["AXSize"] = ["width": sz.width, "height": sz.height] }
        if let val = element.value() {
            if let s = val as? String { result["AXValue"] = s }
            else if let n = val as? NSNumber { result["AXValue"] = n }
            else { result["AXValue"] = String(describing: val) }
        }
        if let url = element.url() { result["AXURL"] = url.absoluteString }
        if let placeholder = element.placeholderValue() { result["AXPlaceholderValue"] = placeholder }
        return result
    }

    // MARK: - App Name → Bundle ID Resolution

    // MARK: - Installed Apps Discovery
    //
    // The previous implementation was a 50-entry hardcoded lookup table
    // that had to be manually maintained every time Apple shipped a new
    // built-in app or the user installed a third-party app the agent
    // wanted to target. We now scan the standard macOS app directories
    // at first access, read each .app bundle's Info.plist, and build the
    // name→bundleID map from CFBundleIdentifier + CFBundleName /
    // CFBundleDisplayName. Adding an app to /Applications automatically
    // makes it discoverable — no code changes, no hardcoding.
    //
    // The scan is lazy (computed on first access via the static let
    // initializer) and cached for the process lifetime. Cost: ~50-200ms
    // I/O for the initial scan, depending on how many apps are installed.
    // Apps installed AFTER startup won't appear until the next launch,
    // which is acceptable for almost every use case.

    /// Installed apps discovered at first access. Maps lowercased display
    /// name (and a no-spaces variant) to bundle identifier. Source of
    /// truth: every .app bundle in the standard macOS app directories.
    private static let knownApps: [String: String] = {
        var map: [String: String] = [:]
        let fm = FileManager.default
        let directories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        for dir in directories {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let appPath = "\(dir)/\(entry)"
                let plistPath = "\(appPath)/Contents/Info.plist"
                guard let plist = NSDictionary(contentsOfFile: plistPath),
                      let bundleID = plist["CFBundleIdentifier"] as? String,
                      !bundleID.isEmpty else { continue }
                // Prefer CFBundleDisplayName, fall back to CFBundleName,
                // then to the .app filename without extension. Some apps
                // (especially older ones) only set one of these.
                let displayName = (plist["CFBundleDisplayName"] as? String)
                    ?? (plist["CFBundleName"] as? String)
                    ?? (entry as NSString).deletingPathExtension
                let lower = displayName.lowercased()
                // Insert the lowercased display name and a no-spaces
                // variant so "photobooth" matches "Photo Booth".
                map[lower] = bundleID
                let noSpaces = lower.replacingOccurrences(of: " ", with: "")
                if noSpaces != lower { map[noSpaces] = bundleID }
            }
        }
        return map
    }()

    /// Pure name → bundle ID lookup. **No side effects** — does NOT launch the
    /// app and does NOT bring it to front. Use this for read-only accessibility
    /// queries (find_element, get_properties, list_windows, inspect_element,
    /// screenshot, etc.) where you do NOT want resolveBundleId's auto-launch
    /// behavior to spawn an app the user never asked to open.
    ///
    /// Returns nil for empty/focused/frontmost input. Returns the input
    /// unchanged if no match (so callers can pass arbitrary bundle IDs through).
    @MainActor
    public func lookupBundleId(_ input: String?) -> String? {
        guard let input = input else { return nil }

        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        if lower == "focused" || lower == "frontmost" || lower.isEmpty { return nil }

        // Already a bundle ID (contains dots)
        if input.contains(".") { return input }

        // Static lookup table (works even if app isn't running)
        if let bid = Self.knownApps[lower] { return bid }
        // Try without spaces: "photobooth" → "photo booth"
        let noSpaces = lower.replacingOccurrences(of: " ", with: "")
        if let bid = Self.knownApps.first(where: { $0.key.replacingOccurrences(of: " ", with: "") == noSpaces })?.value {
            return bid
        }

        // Search running apps by name (no launch — only matches if running)
        let apps = RunningApplicationHelper.allApplications()
        if let match = apps.first(where: { ($0.localizedName ?? "").lowercased() == lower }) {
            return match.bundleIdentifier
        }
        if let match = apps.first(where: { ($0.localizedName ?? "").lowercased().contains(lower) }) {
            return match.bundleIdentifier
        }

        return input
    }

    /// Resolve an app name or bundle ID to an actual bundle ID, **and auto-launch**
    /// the app if it isn't already running. Use this for write/action operations
    /// (click_element, type_into_element, perform_action, set_window_frame, etc.)
    /// that require the target app to be live.
    ///
    /// For read-only queries that should NOT cause an app launch, call
    /// `lookupBundleId(_:)` instead.
    @MainActor
    public func resolveBundleId(_ input: String?) -> String? {
        guard let input = input else { return nil }

        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        if lower == "focused" || lower == "frontmost" || lower.isEmpty { return nil }

        // Already a bundle ID (contains dots) — still launch it. Before, this
        // short-circuited without launching, which forced cloud LLMs to call
        // open_app first just to get Photo Booth running before click_element.
        // Apple AI gets away without that extra turn because it happens to pass
        // the natural name which flows through the launchIfNeeded path below.
        if input.contains(".") {
            launchIfNeeded(bundleId: input)
            return input
        }

        // Static lookup table (works even if app isn't running)
        if let bid = Self.knownApps[lower] {
            launchIfNeeded(bundleId: bid)
            return bid
        }
        // Try without spaces: "photobooth" → "photo booth"
        let noSpaces = lower.replacingOccurrences(of: " ", with: "")
        if let bid = Self.knownApps.first(where: { $0.key.replacingOccurrences(of: " ", with: "") == noSpaces })?.value {
            launchIfNeeded(bundleId: bid)
            return bid
        }

        // Search running apps by name
        let apps = RunningApplicationHelper.allApplications()
        if let match = apps.first(where: { ($0.localizedName ?? "").lowercased() == lower }) {
            return match.bundleIdentifier
        }
        if let match = apps.first(where: { ($0.localizedName ?? "").lowercased().contains(lower) }) {
            return match.bundleIdentifier
        }

        return input
    }

    /// Launch app if not running, then activate (bring to front) regardless.
    /// Public wrapper so other files in the AgentAccess module (e.g.
    /// AccessibilityService+Elements.swift's openApp) can run the full launch
    /// pipeline without going through resolveBundleId, which has an early
    /// return for literal bundle IDs and skips launchIfNeeded entirely.
    @MainActor
    func forceLaunchAndActivate(bundleId: String) {
        launchIfNeeded(bundleId: bundleId)
    }

    /// Launch app if not running, then activate (bring to front) regardless.
    /// This is the byte-for-byte 2.6.0 implementation that worked correctly
    /// for ~7 days. The 2.9.1 attempt to "improve" it by switching to
    /// Element.showWindow() broke docked Photo Booth: showWindow() adds a
    /// per-window performAction(.raise) on a window that was just unminimized,
    /// which races against the AX queue and fails silently. The simpler
    /// per-window unminimizeWindow() loop followed by appElement.activate() and
    /// the NSRunningApplication.activate() fallback is the combination that
    /// actually works for the dock-Genie case.
    ///
    /// DO NOT REPLACE THIS WITH showWindow(). It looks equivalent. It is not.
    @MainActor
    private func launchIfNeeded(bundleId: String) {
        if RunningApplicationHelper.applications(withBundleIdentifier: bundleId).isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        // Always activate — handles minimized/docked apps
        if let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first {
            // Unminimize any minimized windows first
            if let appElement = Element.application(for: app),
               let windows = appElement.windows() {
                for window in windows {
                    if window.isMinimized() == true {
                        _ = window.unminimizeWindow()
                    }
                }
                _ = appElement.activate()
            }
            // NSRunningApplication.activate as fallback — works for docked apps
            app.activate()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // MARK: - Helpers

    @MainActor
    public func getProcessName(pid: pid_t) -> String? {
        guard let app = RunningApplicationHelper.runningApplication(pid: pid) else { return nil }
        return app.localizedName ?? app.bundleIdentifier
    }

    public func successJSON(_ data: Any) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: ["success": true, "data": data], options: .sortedKeys),
           let s = String(data: d, encoding: .utf8) { return s }
        return "{\"success\":true}"
    }

    /// True when `json` is a result produced by `successJSON`. Parses instead of
    /// substring-matching so whitespace differences can't cause a false negative.
    public static func isSuccessJSON(_ json: String) -> Bool {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return obj["success"] as? Bool == true
    }

    public func errorJSON(_ msg: String) -> String {
        // Proper JSON escaping (backslashes, newlines, control chars) — a hand-rolled
        // quote-only replacement produced invalid JSON for multi-line messages.
        if let d = try? JSONSerialization.data(withJSONObject: ["success": false, "error": msg], options: .sortedKeys),
           let s = String(data: d, encoding: .utf8) { return s }
        return "{\"success\":false,\"error\":\"unknown\"}"
    }
}
