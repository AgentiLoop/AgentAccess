import AgentAudit
import AXorcist
import Foundation
import AppKit

// MARK: - Wake lazy accessibility trees

/// Some apps only build the accessibility tree of their document content when an
/// assistive app asks for it the way VoiceOver does (AXEnhancedUserInterface) —
/// Pages/Numbers/Keynote expose an empty canvas (a scroll area holding only scroll
/// bars) until then, so the body text could not be found, typed into or read.
/// Chromium/Electron apps use AXManualAccessibility for the same purpose.
extension AccessibilityService {

    @MainActor private static var lastWake: [pid_t: Date] = [:]

    /// True when the window shows a content area with nothing inside it but scroll bars.
    @MainActor
    static func hasHollowContent(_ root: Element, depth: Int = 0) -> Bool {
        guard depth <= 6, let children = root.children(strict: true) else { return false }
        for child in children {
            let r = child.role() ?? ""
            if r == "AXScrollArea" {
                let inner = child.children(strict: true) ?? []
                let size = child.size() ?? .zero
                if size.width > 200, size.height > 200,
                   inner.allSatisfy({ $0.role() == "AXScrollBar" }) { return true }
            } else if r == "AXSplitGroup" || r == "AXGroup" || r == "AXLayoutArea" {
                if hasHollowContent(child, depth: depth + 1) { return true }
            }
        }
        return false
    }

    /// When the app's front window has hollow content, ask the app for its full
    /// tree (AXManualAccessibility, then AXEnhancedUserInterface as VoiceOver
    /// does), wait until `ready` holds (max ~1.5s), then put
    /// AXEnhancedUserInterface back — it can disturb window animations, and the
    /// tree stays built once made. Returns true when it woke the app.
    @MainActor
    @discardableResult
    func wakeAccessibilityTree(_ appElement: Element, ready: () -> Bool) -> Bool {
        guard let pid = appElement.pid() else { return false }
        if let last = Self.lastWake[pid], Date().timeIntervalSince(last) < 5 { return false }
        guard let window = appElement.focusedWindow() ?? appElement.mainWindow(),
              Self.hasHollowContent(window) else { return false }
        Self.lastWake[pid] = Date()
        let ax = appElement.underlyingElement
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var current: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, "AXEnhancedUserInterface" as CFString, &current)
        let wasEnhanced = (current as? Bool) ?? false
        if !wasEnhanced {
            AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        AuditLog.log(.accessibility, "wakeAccessibilityTree(pid: \(pid)) — hollow content, enhanced UI requested")
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            if ready() { break }
        }
        if !wasEnhanced {
            AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        return true
    }
}
