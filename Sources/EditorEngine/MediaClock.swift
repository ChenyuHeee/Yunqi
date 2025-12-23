import Foundation

/// Monotonic host time, represented as nanoseconds.
///
/// Phase 1 note: In real CoreAudio integration, host time will come from the device timestamp.
public typealias MediaHostTimeNanos = UInt64

public struct MediaLoopRange: Sendable, Codable, Hashable {
    /// Inclusive start sample time.
    public var startSampleTime: Int64
    /// Exclusive end sample time.
    public var endSampleTime: Int64

    public init(startSampleTime: Int64, endSampleTime: Int64) {
        self.startSampleTime = startSampleTime
        self.endSampleTime = endSampleTime
    }

    public var length: Int64 {
        max(0, endSampleTime - startSampleTime)
    }
}

/// Media clock bridging host time <-> engine sample time.
///
/// Phase 1 goals:
/// - Deterministic conversion rules (stable rounding)
/// - Loop boundary behavior
///
/// This does not integrate with CoreAudio yet.
public struct MediaClock: Sendable, Codable, Hashable {
    public static let nanosPerSecond: Double = 1_000_000_000

    /// Anchor mapping.
    public var anchorHostTimeNanos: MediaHostTimeNanos
    public var anchorSampleTime: Int64

    /// Sample rate used for conversions.
    public var sampleRate: Double

    public var loop: MediaLoopRange?

    public init(
        anchorHostTimeNanos: MediaHostTimeNanos,
        anchorSampleTime: Int64,
        sampleRate: Double = AudioClock.engineSampleRate,
        loop: MediaLoopRange? = nil
    ) {
        self.anchorHostTimeNanos = anchorHostTimeNanos
        self.anchorSampleTime = max(0, anchorSampleTime)
        self.sampleRate = sampleRate
        self.loop = loop
    }

    /// Convert host time to engine sample time.
    ///
    /// Deterministic rounding: nearest, ties away from zero.
    /// Host times earlier than the anchor clamp to `anchorSampleTime`.
    public func sampleTime(hostTimeNanos: MediaHostTimeNanos) -> Int64 {
        guard hostTimeNanos >= anchorHostTimeNanos else {
            return applyLoopIfNeeded(anchorSampleTime)
        }

        let deltaNanos = Double(hostTimeNanos - anchorHostTimeNanos)
        let deltaSeconds = deltaNanos / Self.nanosPerSecond
        let deltaSamples = (deltaSeconds * sampleRate).rounded(.toNearestOrAwayFromZero)
        let st = anchorSampleTime &+ Int64(deltaSamples)
        return applyLoopIfNeeded(max(0, st))
    }

    /// Convert engine sample time to host time.
    ///
    /// If loop is set, the provided sampleTime is first normalized into the loop range.
    public func hostTimeNanos(sampleTime: Int64) -> MediaHostTimeNanos {
        let st = applyLoopIfNeeded(max(0, sampleTime))
        let deltaSamples = Double(st - anchorSampleTime)
        let deltaSeconds = deltaSamples / sampleRate
        let deltaNanos = (deltaSeconds * Self.nanosPerSecond).rounded(.toNearestOrAwayFromZero)
        if deltaNanos <= 0 { return anchorHostTimeNanos }
        return anchorHostTimeNanos &+ UInt64(deltaNanos)
    }

    /// Update loop range.
    public mutating func setLoop(_ loop: MediaLoopRange?) {
        self.loop = loop
    }

    /// Read monotonic host time now (nanoseconds).
    ///
    /// Note: This is a convenience for non-RT code paths and tests. CoreAudio integration should
    /// supply host time from device timestamps.
    public static func nowHostTimeNanos() -> MediaHostTimeNanos {
        DispatchTime.now().uptimeNanoseconds
    }

    private func applyLoopIfNeeded(_ sampleTime: Int64) -> Int64 {
        guard let loop else { return sampleTime }
        let len = loop.length
        guard len > 0 else { return sampleTime }

        if sampleTime < loop.startSampleTime {
            return loop.startSampleTime
        }
        if sampleTime < loop.endSampleTime {
            return sampleTime
        }

        let offset = sampleTime - loop.startSampleTime
        let wrapped = offset % len
        return loop.startSampleTime + wrapped
    }
}
