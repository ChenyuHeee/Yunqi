import AudioEngine
import Foundation

/// MediaIO-level audio decoding abstraction.
///
/// Notes:
/// - This is NOT realtime-thread API. Decoding and IO must happen off the audio callback.
/// - Output is always float32 interleaved PCM.
/// - Sample-rate conversion to the engine internal rate (48k) is Phase 1 caller-managed via `AudioResampler`.
public protocol AudioDecodeSource: Sendable {
    var sourceFormat: AudioSourceFormat { get }
    var durationFrames: Int64 { get }
    var preferredChunkFrames: Int { get }

    func readPCM(startFrame: Int64, frameCount: Int) throws -> AudioPCMBlock
}

public enum AudioResampleQuality: String, Codable, Sendable {
    case realtime
    case high
}

public protocol AudioResampler: Sendable {
    func process(
        input: AudioPCMBlock,
        fromRate: Double,
        toRate: Double,
        quality: AudioResampleQuality
    ) throws -> AudioPCMBlock
}
