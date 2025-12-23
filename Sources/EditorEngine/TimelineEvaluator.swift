import EditorCore
import Foundation

public struct TimelineEvaluator: Sendable {
    public init() {}

    /// Phase 1 最小评估：在给定时间点，从 timeline 中挑出所有与该时间相交的视频 clip，
    /// 并计算该时间点对应的素材取样时间。
    ///
    /// 约定：
    /// - 仅评估 `.video` 轨
    /// - layer 顺序按 trackIndex 升序（底层先），同轨按 clip.start 排序
    public func evaluateRenderGraph(project: Project, timeSeconds t: Double) -> RenderGraph {
        let time = max(0, t)
        let renderSize = project.meta.renderSize
        let projectDefaultConform = project.meta.spatialConformDefault

        var layers: [VideoLayer] = []

        for track in project.timeline.tracks {
            guard track.kind == .video else { continue }

            // Clips may not be sorted; keep it deterministic.
            let sorted = track.clips.sorted {
                if abs($0.timelineStartSeconds - $1.timelineStartSeconds) > 1e-9 {
                    return $0.timelineStartSeconds < $1.timelineStartSeconds
                }
                return $0.id.uuidString < $1.id.uuidString
            }

            for clip in sorted {
                let clipStart = clip.timelineStartSeconds
                let clipEnd = clip.timelineStartSeconds + max(0, clip.durationSeconds)
                if time < clipStart - 1e-9 || time >= clipEnd - 1e-9 {
                    continue
                }

                let local = max(0, time - clipStart)
                let speed = max(0.0001, clip.speed)
                let sourceTime = clip.sourceInSeconds + local * speed
                let conform = clip.spatialConformOverride ?? projectDefaultConform

                layers.append(
                    VideoLayer(
                        trackId: track.id,
                        clipId: clip.id,
                        assetId: clip.assetId,
                        sourceTimeSeconds: sourceTime,
                        spatialConform: conform
                    )
                )
            }
        }

        return RenderGraph(timeSeconds: time, renderSize: renderSize, video: VideoGraph(layers: layers))
    }
}
