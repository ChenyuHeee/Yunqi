import Foundation

/// Golden test primitives (Phase 1).
///
/// This file intentionally avoids any IO or realtime concerns. It only provides deterministic
/// summary/statistics for comparing rendered PCM blocks across versions.
public enum AudioGolden {
    public static let algorithmVersion: Int = 1

    /// Compute a stable 64-bit hash for interleaved float32 PCM.
    ///
    /// Notes:
    /// - Uses the Float bitPattern (IEEE-754) to avoid locale/formatting issues.
    /// - Stable across processes and machines.
    public static func hash64(interleaved: [Float]) -> UInt64 {
        var hasher = FNV1a64()
        for f in interleaved {
            var bits = f.bitPattern
            withUnsafeBytes(of: &bits) { hasher.combine(bytes: $0) }
        }
        return hasher.value
    }

    /// Compute basic deterministic statistics for interleaved float32 PCM.
    public static func statistics(interleaved: [Float]) -> AudioPCMStatistics {
        guard !interleaved.isEmpty else {
            return AudioPCMStatistics(peak: 0, rms: 0)
        }

        var peak: Float = 0
        var sumSquares: Double = 0

        for x in interleaved {
            let ax = abs(x)
            if ax > peak { peak = ax }
            let d = Double(x)
            sumSquares += d * d
        }

        let meanSquares = sumSquares / Double(interleaved.count)
        let rms = Float((meanSquares).squareRoot())
        return AudioPCMStatistics(peak: peak, rms: rms)
    }

    public static func snapshot(
        format: AudioSourceFormat,
        frameCount: Int,
        interleaved: [Float],
        algorithmVersion: Int = AudioGolden.algorithmVersion
    ) -> AudioPCMGoldenSnapshot {
        AudioPCMGoldenSnapshot(
            algorithmVersion: algorithmVersion,
            format: format,
            frameCount: frameCount,
            stats: statistics(interleaved: interleaved),
            hash64: hash64(interleaved: interleaved)
        )
    }
}

public struct AudioPCMStatistics: Sendable, Codable, Hashable {
    public var peak: Float
    public var rms: Float

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }
}

public struct AudioPCMGoldenSnapshot: Sendable, Codable, Hashable {
    public var algorithmVersion: Int
    public var format: AudioSourceFormat
    public var frameCount: Int
    public var stats: AudioPCMStatistics
    public var hash64: UInt64

    public init(
        algorithmVersion: Int,
        format: AudioSourceFormat,
        frameCount: Int,
        stats: AudioPCMStatistics,
        hash64: UInt64
    ) {
        self.algorithmVersion = algorithmVersion
        self.format = format
        self.frameCount = frameCount
        self.stats = stats
        self.hash64 = hash64
    }
}

private struct FNV1a64 {
    private(set) var value: UInt64 = 0xcbf29ce484222325

    mutating func combine(bytes: UnsafeRawBufferPointer) {
        for b in bytes {
            value ^= UInt64(b)
            value &*= 0x00000100000001B3
        }
    }
}
