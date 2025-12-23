import EditorCore
import Foundation

/// Sample-accurate time mapping helpers for audio.
///
/// Phase 1: Pure, deterministic math utilities only (no IO, no CoreAudio integration).
public struct AudioTimeMap: Sendable, Codable, Hashable {
    public var sampleRate: Double

    /// Timeline placement in engine sample time.
    public var timelineStartSampleTime: Int64
    public var timelineDurationSamples: Int64

    /// Source placement in source samples (at `sampleRate`).
    public var sourceInSampleTime: Int64

    /// Optional source trim window.
    /// When set, mapped source sample times outside this range return `nil`.
    ///
    /// This represents the post-trim usable region of the underlying asset, in source samples.
    public var sourceTrim: AudioTrimRange?

    /// Playback.
    /// - `speed = 1` means 1 timeline second == 1 source second
    /// - `speed = 2` means timeline runs twice as fast through source
    public var speed: Double
    public var reverseMode: AudioReversePlaybackMode

    /// Optional looping within the *source* region.
    /// When set, source time wraps within this range.
    public var loop: AudioLoopRange?

    public init(
        sampleRate: Double,
        timelineStartSampleTime: Int64,
        timelineDurationSamples: Int64,
        sourceInSampleTime: Int64,
        sourceTrim: AudioTrimRange? = nil,
        speed: Double,
        reverseMode: AudioReversePlaybackMode,
        loop: AudioLoopRange? = nil
    ) {
        self.sampleRate = sampleRate
        self.timelineStartSampleTime = max(0, timelineStartSampleTime)
        self.timelineDurationSamples = max(0, timelineDurationSamples)
        self.sourceInSampleTime = max(0, sourceInSampleTime)
        self.sourceTrim = sourceTrim
        self.speed = speed
        self.reverseMode = reverseMode
        self.loop = loop
    }

    /// Returns a copy of this map with an additional slip offset applied to `sourceInSampleTime`.
    ///
    /// Slip means changing the source start without changing the clip's timeline placement.
    public func applyingSlip(offsetSamples: Int64) -> AudioTimeMap {
        var copy = self
        copy.sourceInSampleTime = max(0, copy.sourceInSampleTime &+ offsetSamples)
        return copy
    }

    /// Returns mapped source sample time for a given timeline sample time.
    ///
    /// - Returns `nil` when outside the clip's timeline range.
    /// - Deterministic rounding: nearest, ties away from zero.
    public func sourceSampleTime(forTimelineSampleTime t: Int64) -> Int64? {
        guard sampleRate > 0, sampleRate.isFinite else { return nil }
        guard speed.isFinite, speed > 0 else { return nil }
        let t0 = timelineStartSampleTime
        let dt = t - t0
        guard dt >= 0, dt < timelineDurationSamples else { return nil }

        // Convert dt samples -> seconds -> scaled source samples.
        let localSeconds = Double(dt) / sampleRate
        let scaledSourceSeconds = localSeconds * speed
        let scaledSourceSamples = (scaledSourceSeconds * sampleRate).rounded(.toNearestOrAwayFromZero)

        let forward = sourceInSampleTime &+ Int64(scaledSourceSamples)

        let mapped: Int64
        switch reverseMode {
        case .mute:
            // Still provide mapping; renderer can decide to output silence.
            mapped = forward
        case .roughReverse, .highQualityReverse:
            // Reverse mapping within the implied source span.
            // Define sourceOutExclusive = sourceIn + timelineDuration * speed (in samples).
            let outExclusiveSeconds = (Double(timelineDurationSamples) / sampleRate) * speed
            let outExclusiveSamples = (outExclusiveSeconds * sampleRate).rounded(.toNearestOrAwayFromZero)
            let outExclusive = sourceInSampleTime &+ Int64(outExclusiveSamples)
            // Reverse should map the first timeline sample to the last valid source sample.
            // If length is 0 (shouldn't happen with dt guard), fall back to `sourceInSampleTime`.
            let length = Int64(outExclusiveSamples)
            if length <= 0 {
                mapped = sourceInSampleTime
            } else {
                mapped = (outExclusive &- 1) &- Int64(scaledSourceSamples)
            }
        }

        let clamped = max(0, mapped)
        let looped = loop.map { $0.wrap(sampleTime: clamped) } ?? clamped

        if let trim = sourceTrim {
            if looped < trim.inSampleTime || looped >= trim.outSampleTime {
                return nil
            }
        }
        return looped
    }
}

public struct AudioTrimRange: Sendable, Codable, Hashable {
    /// Inclusive trim in.
    public var inSampleTime: Int64
    /// Exclusive trim out.
    public var outSampleTime: Int64

    public init(inSampleTime: Int64, outSampleTime: Int64) {
        self.inSampleTime = max(0, inSampleTime)
        self.outSampleTime = max(self.inSampleTime, outSampleTime)
    }

    public var length: Int64 {
        max(0, outSampleTime - inSampleTime)
    }
}

public struct AudioLoopRange: Sendable, Codable, Hashable {
    /// Inclusive loop start.
    public var startSampleTime: Int64
    /// Exclusive loop end.
    public var endSampleTime: Int64

    public init(startSampleTime: Int64, endSampleTime: Int64) {
        self.startSampleTime = max(0, startSampleTime)
        self.endSampleTime = max(self.startSampleTime, endSampleTime)
    }

    public var length: Int64 {
        max(0, endSampleTime - startSampleTime)
    }

    /// Wrap a sampleTime into the loop range.
    ///
    /// - If loop length is 0, returns input.
    /// - If sampleTime is before start, clamps to start.
    public func wrap(sampleTime: Int64) -> Int64 {
        let len = length
        guard len > 0 else { return sampleTime }
        if sampleTime < startSampleTime { return startSampleTime }
        if sampleTime < endSampleTime { return sampleTime }
        let offset = sampleTime - startSampleTime
        let wrapped = offset % len
        return startSampleTime + wrapped
    }
}
