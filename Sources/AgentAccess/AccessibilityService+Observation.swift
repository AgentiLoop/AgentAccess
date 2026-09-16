import AgentAudit
import AXorcist
import Foundation
import AppKit

// MARK: - Token-based streaming observation (AXObserverCenter)
//
// `observeNotifications` (AccessibilityService+AXorcist.swift) is a one-shot
// ObserveCommand. This file exposes AXorcist's AXObserverCenter subscribe /
// unsubscribe API so callers can start a subscription, drain buffered events
// across multiple tool calls, and stop it.

/// Main-actor registry of live subscriptions and their buffered events.
@MainActor
final class AXObservationRegistry {
    static let shared = AXObservationRegistry()

    struct Session {
        let pid: pid_t
        let bundleId: String?
        var tokens: [SubscriptionToken]
        var events: [[String: Any]]
    }

    private(set) var sessions: [String: Session] = [:]
    private let maxBufferedEvents = 500

    func register(pid: pid_t, bundleId: String?, tokens: [SubscriptionToken]) -> String {
        let id = UUID().uuidString
        sessions[id] = Session(pid: pid, bundleId: bundleId, tokens: tokens, events: [])
        return id
    }

    func setTokens(_ tokens: [SubscriptionToken], for id: String) {
        sessions[id]?.tokens = tokens
    }

    func append(_ event: [String: Any], to id: String) {
        guard var session = sessions[id] else { return }
        session.events.append(event)
        if session.events.count > maxBufferedEvents {
            session.events.removeFirst(session.events.count - maxBufferedEvents)
        }
        sessions[id] = session
    }

    func drain(_ id: String, clear: Bool) -> [[String: Any]]? {
        guard var session = sessions[id] else { return nil }
        let events = session.events
        if clear {
            session.events.removeAll()
            sessions[id] = session
        }
        return events
    }

    func remove(_ id: String) -> Session? {
        sessions.removeValue(forKey: id)
    }
}

extension AccessibilityService {

    /// Start a streaming subscription for one or more AX notifications on an app
    /// (optionally scoped to an element matched by role/title/value).
    /// Returns an `observerId` to pass to `pollObservations` / `stopObserving`.
    @MainActor
    public func startObserving(
        appBundleId: String?,
        notifications: [String],
        role: String? = nil,
        title: String? = nil,
        value: String? = nil
    ) -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        guard !notifications.isEmpty else {
            return errorJSON("notifications must contain at least one AX notification name (e.g. AXValueChanged, AXFocusedUIElementChanged, AXWindowCreated)")
        }
        let resolved = lookupBundleId(appBundleId)
        let app: NSRunningApplication?
        if let bundleId = resolved {
            app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first
        } else {
            app = RunningApplicationHelper.frontmostApplication
        }
        guard let app else {
            return errorJSON("App not running: \(resolved ?? appBundleId ?? "frontmost")")
        }
        AuditLog.log(.accessibility, "startObserving(app: \(resolved ?? "frontmost"), notifications: \(notifications))")

        var axNotifications: [AXNotification] = []
        for name in notifications {
            guard let n = AXNotification(rawValue: name) else {
                return errorJSON("Invalid notification name: \(name)")
            }
            axNotifications.append(n)
        }

        var scope: Element? = nil
        if role != nil || title != nil || value != nil {
            guard let found = findAXElement(role: role, title: title, value: value, appBundleId: resolved) else {
                return errorJSON("Element not found")
            }
            scope = found
        }

        let pid = app.processIdentifier
        let observerId = AXObservationRegistry.shared.register(pid: pid, bundleId: resolved, tokens: [])
        var tokens: [SubscriptionToken] = []
        for notification in axNotifications {
            let result = AXObserverCenter.shared.subscribe(
                pid: pid,
                element: scope,
                notification: notification
            ) { pid, notification, rawElement, userInfo in
                let element = Element(rawElement)
                var event: [String: Any] = [
                    "notification": notification.rawValue,
                    "pid": Int(pid),
                    "timestamp": Date().timeIntervalSince1970
                ]
                if let r = element.role() { event["AXRole"] = r }
                if let t = element.title() { event["AXTitle"] = t }
                if let v = element.value() {
                    event["AXValue"] = (v as? String) ?? (v as? NSNumber) ?? String(describing: v)
                }
                if let userInfo, !userInfo.isEmpty {
                    event["userInfo"] = userInfo.mapValues { String(describing: $0) }
                }
                AXObservationRegistry.shared.append(event, to: observerId)
            }
            switch result {
            case .success(let token):
                tokens.append(token)
            case .failure(let error):
                for t in tokens { try? AXObserverCenter.shared.unsubscribe(token: t) }
                _ = AXObservationRegistry.shared.remove(observerId)
                return errorJSON("Subscribe failed for \(notification.rawValue): \(error)")
            }
        }
        AXObservationRegistry.shared.setTokens(tokens, for: observerId)
        return successJSON([
            "observerId": observerId,
            "app": app.bundleIdentifier ?? "",
            "pid": Int(pid),
            "notifications": notifications,
            "scoped": scope != nil
        ])
    }

    /// Return events buffered since the last poll (or since start).
    @MainActor
    public func pollObservations(observerId: String, clear: Bool = true) -> String {
        guard let events = AXObservationRegistry.shared.drain(observerId, clear: clear) else {
            return errorJSON("Unknown observerId: \(observerId)")
        }
        return successJSON(["observerId": observerId, "events": events, "count": events.count])
    }

    /// Stop a subscription and discard its buffered events.
    @MainActor
    public func stopObserving(observerId: String) -> String {
        guard let session = AXObservationRegistry.shared.remove(observerId) else {
            return errorJSON("Unknown observerId: \(observerId)")
        }
        AuditLog.log(.accessibility, "stopObserving(\(observerId), pid: \(session.pid))")
        var failures = 0
        for token in session.tokens {
            do { try AXObserverCenter.shared.unsubscribe(token: token) } catch { failures += 1 }
        }
        return successJSON([
            "observerId": observerId,
            "unsubscribed": session.tokens.count - failures,
            "failed": failures,
            "droppedEvents": session.events.count
        ])
    }

    /// List active observation sessions.
    @MainActor
    public func listObservations() -> String {
        let list = AXObservationRegistry.shared.sessions.map { id, s -> [String: Any] in
            ["observerId": id, "pid": Int(s.pid), "app": s.bundleId ?? "", "subscriptions": s.tokens.count, "bufferedEvents": s.events.count]
        }
        return successJSON(["observers": list, "count": list.count])
    }
}
