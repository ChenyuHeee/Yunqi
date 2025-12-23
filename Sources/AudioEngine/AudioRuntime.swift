import Foundation

public struct AudioProcessContext: Sendable, Hashable {
    /// Engine sampleTime for the first frame in this block.
    public var startSampleTime: Int64

    /// Fixed engine sample rate (Phase 1).
    public var sampleRate: Double

    /// Render quality tier.
    public var quality: AudioRenderQuality

    public init(startSampleTime: Int64, sampleRate: Double = 48_000, quality: AudioRenderQuality) {
        self.startSampleTime = startSampleTime
        self.sampleRate = sampleRate
        self.quality = quality
    }
}

public protocol AudioNodeRuntime: Sendable {
    func prepare(format: AudioSourceFormat, maxFrames: Int) throws
    func reset()

    /// Must be realtime-safe (no allocation/locks/IO/logging).
    func process(context: AudioProcessContext, frameCount: Int, pool: any AudioBufferPool) -> AudioBufferLease
}

public protocol RealtimeAudioRenderer: Sendable {
    func start() throws
    func stop()

    func setRate(_ rate: Double)
    func seek(toSampleTime sampleTime: Int64)

    /// Configure engine-sampleTime loop range.
    ///
    /// Semantics: `range.lowerBound` is inclusive, `range.upperBound` is exclusive.
    /// Pass nil to disable looping.
    func setLoop(_ range: Range<Int64>?)
}

public extension RealtimeAudioRenderer {
    func setLoop(_ range: Range<Int64>?) {
        // Default: no-op for protocol skeleton.
        _ = range
    }
}

public protocol OfflineAudioRenderer: Sendable {
    func render(startSampleTime: Int64, frameCount: Int, format: AudioSourceFormat) throws -> AudioPCMBlock
}
