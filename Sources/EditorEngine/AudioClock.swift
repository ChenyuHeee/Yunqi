import Foundation

/// Engine-level clock utilities.
///
/// Per docs/audio-todolist.md §13.1 / §14.2: internal audio timebase is fixed 48k.
public struct AudioClock: Sendable, Hashable, Codable {
    public static let engineSampleRate: Double = 48_000

    public var sampleRate: Double

    public init(sampleRate: Double = AudioClock.engineSampleRate) {
        self.sampleRate = sampleRate
    }

    /// Convert timeline seconds to engine sampleTime (Int64) with deterministic rounding.
    public func sampleTime(timelineSeconds: Double) -> Int64 {
        let seconds = max(0, timelineSeconds)
        let exact = seconds * sampleRate
        // Deterministic rounding rule: nearest, ties away from zero.
        return Int64(exact.rounded(.toNearestOrAwayFromZero))
    }

    public func timelineSeconds(sampleTime: Int64) -> Double {
        Double(sampleTime) / sampleRate
    }
}

public enum PlaybackSyncPolicy: String, Codable, Sendable {
    /// Audio is the master clock; video should follow.
    case audioMaster
    /// Video is the master clock; audio follows (potentially via buffering/resampling).
    case videoMaster
    /// External master (future): timecode/MTC/etc.
    case external
}
