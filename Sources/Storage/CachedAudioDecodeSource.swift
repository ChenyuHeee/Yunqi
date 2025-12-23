import AudioEngine
import Foundation
import MediaIO

/// A decoding wrapper that persists decoded PCM blocks using `AudioPCMCache`.
///
/// This is intended for non-realtime contexts (background decode/precompute, offline render, etc.).
///
/// Note: `assetFingerprint` is captured at initialization time. If the underlying file changes,
/// create a new `CachedAudioDecodeSource` (and upstream) to avoid reusing stale cache entries.
public final class CachedAudioDecodeSource: AudioDecodeSource, @unchecked Sendable {
    public var sourceFormat: AudioSourceFormat { upstream.sourceFormat }
    public var durationFrames: Int64 { upstream.durationFrames }
    public var preferredChunkFrames: Int { upstream.preferredChunkFrames }

    private let upstream: any AudioDecodeSource
    private let cache: AudioPCMCache

    private let assetId: UUID
    private let clipId: UUID
    private let planStableHash64: UInt64
    private let algorithmVersion: Int

    private let assetURL: URL?
    private let assetFingerprint: String?

    public init(
        upstream: any AudioDecodeSource,
        cache: AudioPCMCache,
        assetId: UUID,
        clipId: UUID,
        planStableHash64: UInt64,
        algorithmVersion: Int,
        assetURL: URL? = nil
    ) {
        self.upstream = upstream
        self.cache = cache
        self.assetId = assetId
        self.clipId = clipId
        self.planStableHash64 = planStableHash64
        self.algorithmVersion = algorithmVersion
        self.assetURL = assetURL
        self.assetFingerprint = assetURL.flatMap { AssetFingerprint.compute(url: $0) }
    }

    public func readPCM(startFrame: Int64, frameCount: Int) throws -> AudioPCMBlock {
        let start = max(0, startFrame)
        let requested = max(0, frameCount)
        let base = AudioCacheKey(
            assetId: assetId,
            clipId: clipId,
            planStableHash64: planStableHash64,
            algorithmVersion: algorithmVersion,
            format: upstream.sourceFormat,
            assetFingerprint: assetFingerprint
        )

        let key = AudioPCMCache.SegmentKey(base: base, startFrame: start, frameCount: requested)

        return try cache.loadOrCompute(key: key) {
            try upstream.readPCM(startFrame: start, frameCount: requested)
        }
    }
}
