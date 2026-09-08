import Foundation

/// Timeout and delay constants for accessibility automation.
public let automationStartTimeout: TimeInterval = 9000
public let automationFinishTimeout: TimeInterval = 18000
public let automationMaxDelay: TimeInterval = 5

/// Default per-call budget for element lookups (find/wait/click/type). These
/// calls poll synchronously on the main actor, so the default must be short —
/// callers that genuinely need to wait longer pass an explicit `timeout:`.
public let elementSearchTimeout: TimeInterval = 10
