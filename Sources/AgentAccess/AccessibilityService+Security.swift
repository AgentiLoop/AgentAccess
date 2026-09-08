import AgentAudit
import AXorcist
import Foundation
import AppKit

// MARK: - Security Extension for AccessibilityService

extension AccessibilityService {

    // MARK: - Cached Permission State

    private nonisolated(unsafe) static var _permissionGranted = false
    private nonisolated(unsafe) static var _promptShown = false

    // MARK: - Permission Methods

    /// Check if the app has Accessibility permissions (cached once granted).
    /// Uses AXIsProcessTrusted() directly since AXPermissionHelpers is @MainActor restricted.
    public static func hasAccessibilityPermission() -> Bool {
        if _permissionGranted { return true }
        let granted = AXIsProcessTrusted()
        if granted { _permissionGranted = true }
        return granted
    }

    /// Request Accessibility permissions — opens System Settings directly.
    public static func requestAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            _permissionGranted = true
            return true
        }
        if !_promptShown {
            _promptShown = true
            let options: [String: Bool] = ["AXTrustedCheckOptionPrompt": true]
            let result = AXIsProcessTrustedWithOptions(options as CFDictionary)
            if result { _permissionGranted = true; return true }
            startPermissionPolling()
            return false
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPermissionPolling()
        return false
    }

    private nonisolated(unsafe) static var _pollingTask: Task<Void, Never>?

    private static func startPermissionPolling() {
        guard _pollingTask == nil else { return }
        _pollingTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if AXIsProcessTrusted() {
                    await MainActor.run { relaunchApp() }
                    return
                }
            }
        }
    }

    @MainActor
    private static func relaunchApp() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// UserDefaults key holding an array of restricted action/role identifiers
    /// (e.g. `["AXPress", "AXTextField"]`). Empty/absent = nothing restricted.
    public static let restrictedIDsKey = "AccessibilityRestrictedIDs"

    /// True when accessibility is globally disabled, or `id` (an AX action or
    /// role) is listed under `restrictedIDsKey`.
    public static func isRestricted(_ id: String) -> Bool {
        let defaults = UserDefaults.standard
        let globallyEnabled = defaults.object(forKey: "AccessibilityGlobalEnabled") as? Bool ?? true
        if !globallyEnabled { return true }
        let restricted = defaults.stringArray(forKey: restrictedIDsKey) ?? []
        return restricted.contains(id)
    }
}
