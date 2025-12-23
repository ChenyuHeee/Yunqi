import AudioEngine
import EditorCore
import Foundation

/// Per docs/audio-todolist.md §14.5: a stable key for cached audio artifacts.
public struct AudioCacheKey: Codable, Sendable, Hashable {
    public var assetId: UUID
    public var clipId: UUID

    /// Best-effort fingerprint for invalidation (nil when unknown).
    public var assetFingerprint: String?

    /// Hash of the compiled AudioRenderPlan (stable across processes).
    public var planStableHash64: UInt64

    /// Algorithm versioning to prevent stale cache reuse across upgrades.
    public var algorithmVersion: Int

    /// Output format for the cached artifact.
    public var format: AudioSourceFormat

    public init(
        assetId: UUID,
        clipId: UUID,
        planStableHash64: UInt64,
        algorithmVersion: Int,
        format: AudioSourceFormat,
        assetFingerprint: String? = nil
    ) {
        self.assetId = assetId
        self.clipId = clipId
        self.planStableHash64 = planStableHash64
        self.algorithmVersion = algorithmVersion
        self.format = format
        self.assetFingerprint = assetFingerprint
    }
}
