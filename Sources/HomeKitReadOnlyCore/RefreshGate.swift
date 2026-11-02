import Foundation

/// Whole-round admission control, shared by manual and periodic refresh requests.
/// Callers supply monotonic time so wall-clock corrections do not affect scheduling.
public struct RefreshGate {
    public private(set) var isRunning = false
    private var finishedAt: TimeInterval?
    public init() {}
    public mutating func begin(at now: TimeInterval, automatic: Bool, minimumInterval: TimeInterval = 15) -> Bool {
        guard !isRunning else { return false }
        if automatic, let finishedAt, now-finishedAt < minimumInterval { return false }
        isRunning = true; return true
    }
    public mutating func finish(at now: TimeInterval) { isRunning = false; finishedAt = now }
}
