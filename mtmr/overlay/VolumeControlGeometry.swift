import Foundation

/// Shared value bounds for the brightness and volume controllers.
enum VolumeControlGeometry {
    static func clamped(_ volume: Double) -> Double {
        guard volume.isFinite else { return 0 }
        return min(1, max(0, volume))
    }
}

/// Per-slider ownership and latest-value coalescing, using monotonic time.
struct UniversalSliderState {
    static let writeInterval: TimeInterval = 1.0 / 60
    static let refreshQuietSeconds: TimeInterval = 0.6
    private var touching = false
    private var changedAt: TimeInterval?
    private var writtenAt: TimeInterval?
    private var pendingValue: Double?

    mutating func setTouching(_ touching: Bool) {
        self.touching = touching
    }

    func ignoresRefresh(at time: TimeInterval) -> Bool {
        if touching { return true }
        guard let changedAt = changedAt else { return false }
        return time - changedAt < Self.refreshQuietSeconds
    }

    mutating func queue(_ value: Double, at time: TimeInterval) {
        pendingValue = VolumeControlGeometry.clamped(value)
        changedAt = time
    }

    func nextWriteDelay(at time: TimeInterval) -> TimeInterval? {
        guard pendingValue != nil else { return nil }
        guard let writtenAt = writtenAt else { return 0 }
        return max(0, Self.writeInterval - (time - writtenAt))
    }

    mutating func takeWrite(at time: TimeInterval) -> Double? {
        guard nextWriteDelay(at: time) == 0 else { return nil }
        let value = pendingValue
        pendingValue = nil
        writtenAt = time
        return value
    }
}

struct UniversalControlPress {
    enum Action { case open, exit }
    static let holdSeconds: TimeInterval = 0.5
    private var startedAt: TimeInterval?
    private var exited = false

    mutating func begin(at time: TimeInterval) {
        startedAt = time
        exited = false
    }

    mutating func hold(at time: TimeInterval) -> Bool {
        guard let startedAt = startedAt else { return false }
        guard !exited else { return false }
        guard time - startedAt >= Self.holdSeconds else { return false }
        exited = true
        return true
    }

    mutating func end(at time: TimeInterval) -> Action? {
        defer { cancel() }
        guard let startedAt = startedAt else { return nil }
        guard !exited else { return nil }
        return time - startedAt >= Self.holdSeconds ? .exit : .open
    }

    mutating func cancel() {
        startedAt = nil
        exited = false
    }
}
