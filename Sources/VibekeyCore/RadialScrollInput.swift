import Foundation

/// Convert wheel ticks or precise trackpad deltas into deliberate sector moves.
/// Acceleration never skips sectors within a single event.
public struct RadialScrollInput {
    private var pending: Double = 0
    private var precise: Bool?

    public init() {}

    public mutating func reset() {
        pending = 0; precise = nil
    }

    public mutating func consume(deltaY: Double, precise: Bool) -> Int {
        guard deltaY.isFinite, deltaY != 0 else { return 0 }
        if self.precise != precise || (pending != 0 && (pending > 0) != (deltaY > 0)) {
            pending = 0
        }
        self.precise = precise
        pending += deltaY
        let threshold: Double = precise ? 12 : 1
        guard abs(pending) >= threshold else { return 0 }
        let direction = pending > 0 ? -1 : 1
        pending = pending.truncatingRemainder(dividingBy: threshold)
        return direction
    }
}
