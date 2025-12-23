import EditorCore
import Foundation

/// Engine 层的“这一帧要渲染什么”的纯数据表达。
///
/// 注意：这是 Phase 1 的最小形态（只描述视频层的素材取样点）。
/// 后续会扩展：变换/不透明度/效果链/字幕/转场/调整层、以及音频图。
public struct RenderGraph: Sendable, Equatable {
    public var timeSeconds: Double
    public var renderSize: RenderSize
    public var video: VideoGraph

    public init(timeSeconds: Double, renderSize: RenderSize, video: VideoGraph) {
        self.timeSeconds = timeSeconds
        self.renderSize = renderSize
        self.video = video
    }
}

public struct VideoGraph: Sendable, Equatable {
    /// 自底向上的层序（0 在最底层）。
    public var layers: [VideoLayer]

    public init(layers: [VideoLayer]) {
        self.layers = layers
    }
}

public struct VideoLayer: Sendable, Equatable {
    public var trackId: UUID
    public var clipId: UUID

    public var assetId: UUID

    /// 本帧应取样素材的时间点（单位：秒）。
    public var sourceTimeSeconds: Double

    /// Final Cut-style spatial conform (effective: clip override or project default).
    public var spatialConform: SpatialConform

    public init(
        trackId: UUID,
        clipId: UUID,
        assetId: UUID,
        sourceTimeSeconds: Double,
        spatialConform: SpatialConform
    ) {
        self.trackId = trackId
        self.clipId = clipId
        self.assetId = assetId
        self.sourceTimeSeconds = sourceTimeSeconds
        self.spatialConform = spatialConform
    }
}
