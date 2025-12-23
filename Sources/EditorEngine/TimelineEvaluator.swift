import EditorCore
import Foundation

public struct TimelineEvaluator: Sendable {
    public init() {}

    private func derivedNodeID(base: UUID, salt: UInt64) -> AudioNodeID {
        var bytes = base.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            for i in 0..<raw.count {
                let shift = UInt64((i % 8) * 8)
                raw[i] ^= UInt8(truncatingIfNeeded: salt >> shift)
            }
        }
        return AudioNodeID(UUID(uuid: bytes))
    }

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

    /// Phase 1 最小评估：在给定时间点，从 timeline 中挑出所有与该时间相交的音频 clip。
    ///
    /// 注意：这里先只生成“表达能力够用”的 AudioGraph 骨架（可序列化/可哈希）。
    /// Realtime/Offline 的具体 DSP 实现会在后续由 AudioGraphCompiler/Renderer 接管。
    public func evaluateAudioGraph(project: Project, timeSeconds t: Double) -> AudioGraph {
        let time = max(0, t)

        let clock = AudioClock()

        var nodes: [AudioNodeID: AudioNodeSpec] = [:]
        var edges: [AudioEdge] = []
        var clipSnapshots: [AudioClipParameterSnapshot] = []

        // Deterministic ordering.
        let tracks = project.timeline.tracks.enumerated().sorted { $0.offset < $1.offset }

        // Solo semantics (Phase 1): if any audio track or audio clip is solo, only those contribute.
        let hasAnySolo: Bool = project.timeline.tracks.contains { track in
            guard track.kind == .audio else { return false }
            if track.isSolo { return true }
            return track.clips.contains { $0.audioIsSolo }
        }

        var lastBus: AudioNodeID?
        for (_, track) in tracks {
            guard track.kind == .audio else { continue }

            if hasAnySolo, track.isSolo == false {
                // Track not soloed; it can still contribute if it has soloed clips.
                if !track.clips.contains(where: { $0.audioIsSolo }) {
                    continue
                }
            }

            let sorted = track.clips.sorted {
                if abs($0.timelineStartSeconds - $1.timelineStartSeconds) > 1e-9 {
                    return $0.timelineStartSeconds < $1.timelineStartSeconds
                }
                return $0.id.uuidString < $1.id.uuidString
            }

            for clip in sorted {
                if hasAnySolo {
                    // If any solo exists, require the clip OR its track to be solo.
                    if !track.isSolo, !clip.audioIsSolo {
                        continue
                    }
                }

                let clipStart = clip.timelineStartSeconds
                let clipEnd = clip.timelineStartSeconds + max(0, clip.durationSeconds)
                if time < clipStart - 1e-9 || time >= clipEnd - 1e-9 {
                    continue
                }

                // Node IDs must be deterministic for caching and reproducibility.
                let src = AudioNodeID(clip.id)
                nodes[src] = .source(clipId: clip.id, assetId: clip.assetId, format: nil)

                // TimeMap node (semantic decisions are already encoded in the project model)
                let timeMap = derivedNodeID(base: clip.id, salt: 0xA11D_1001)
                let speed = max(0.0001, clip.speed)

                let timelineStartSampleTime = clock.sampleTime(timelineSeconds: clip.timelineStartSeconds)
                let timelineDurationSamples = clock.sampleTime(timelineSeconds: max(0, clip.durationSeconds))
                let sourceInSampleTime = clock.sampleTime(timelineSeconds: max(0, clip.sourceInSeconds))

                // Optional loop range expressed in source seconds.
                let loop: AudioLoopRange? = clip.audioLoopRangeSeconds.flatMap { r in
                    let start = clock.sampleTime(timelineSeconds: r.startSeconds)
                    let end = clock.sampleTime(timelineSeconds: r.endSeconds)
                    if end <= start { return nil }
                    return AudioLoopRange(startSampleTime: start, endSampleTime: end)
                }

                // Derived source trim window: the implied source span consumed by this clip.
                // This makes trim/speed semantics explicit at sample-precision.
                let outExclusiveSeconds = (Double(timelineDurationSamples) / clock.sampleRate) * speed
                let outExclusiveSamples = (outExclusiveSeconds * clock.sampleRate).rounded(.toNearestOrAwayFromZero)
                let sourceTrim = AudioTrimRange(
                    inSampleTime: sourceInSampleTime,
                    outSampleTime: sourceInSampleTime &+ Int64(outExclusiveSamples)
                )

                let map = AudioTimeMap(
                    sampleRate: clock.sampleRate,
                    timelineStartSampleTime: timelineStartSampleTime,
                    timelineDurationSamples: timelineDurationSamples,
                    sourceInSampleTime: sourceInSampleTime,
                    sourceTrim: sourceTrim,
                    speed: speed,
                    reverseMode: clip.audioReversePlaybackMode,
                    loop: loop
                )

                nodes[timeMap] = .timeMap(mode: clip.audioTimeStretchMode, map: map)
                edges.append(AudioEdge(from: src, to: timeMap))

                // Fade node (Phase 1: semantic envelope; runtime will apply per-sample)
                let fade = derivedNodeID(base: clip.id, salt: 0xA11D_1005)
                let fadeNode: AudioNodeID? = {
                    guard clip.fadeIn != nil || clip.fadeOut != nil else { return nil }

                    var fadeInSamples = clip.fadeIn.map { clock.sampleTime(timelineSeconds: max(0, $0.durationSeconds)) } ?? 0
                    var fadeOutSamples = clip.fadeOut.map { clock.sampleTime(timelineSeconds: max(0, $0.durationSeconds)) } ?? 0

                    fadeInSamples = min(max(0, fadeInSamples), timelineDurationSamples)
                    fadeOutSamples = min(max(0, fadeOutSamples), timelineDurationSamples)
                    // Prevent overlap (Phase 1 deterministic rule).
                    if fadeInSamples &+ fadeOutSamples > timelineDurationSamples {
                        fadeOutSamples = max(0, timelineDurationSamples &- fadeInSamples)
                    }

                    let fadeInSpec: AudioFadeSpec? = {
                        guard let f = clip.fadeIn, fadeInSamples > 0 else { return nil }
                        return AudioFadeSpec(durationSamples: fadeInSamples, shape: f.shape)
                    }()
                    let fadeOutSpec: AudioFadeSpec? = {
                        guard let f = clip.fadeOut, fadeOutSamples > 0 else { return nil }
                        return AudioFadeSpec(durationSamples: fadeOutSamples, shape: f.shape)
                    }()

                    guard fadeInSpec != nil || fadeOutSpec != nil else { return nil }
                    nodes[fade] = .fade(
                        clipId: clip.id,
                        timelineStartSampleTime: timelineStartSampleTime,
                        timelineDurationSamples: timelineDurationSamples,
                        fadeIn: fadeInSpec,
                        fadeOut: fadeOutSpec
                    )
                    edges.append(AudioEdge(from: timeMap, to: fade))
                    return fade
                }()

                // Evaluate automation at clip-local timeline time (Phase 1 point-snapshot).
                let clipLocalTimeSeconds = max(0, time - clipStart)
                let clipVolumeAtT = AudioAutomationEvaluator.value(
                    curve: clip.volumeAutomation,
                    atTimeSeconds: clipLocalTimeSeconds,
                    defaultValue: clip.volume
                )
                let clipPanAtT = AudioAutomationEvaluator.value(
                    curve: clip.panAutomation,
                    atTimeSeconds: clipLocalTimeSeconds,
                    defaultValue: clip.pan
                )

                // Gain/pan nodes (Phase 1: constants; per-sample automation will be added later)
                let gain = derivedNodeID(base: clip.id, salt: 0xA11D_1002)
                let isMuted = track.isMuted || clip.audioIsMuted
                let effectiveGain = isMuted ? 0.0 : (clip.gain * clipVolumeAtT * track.volume)
                nodes[gain] = .gain(value: effectiveGain)
                edges.append(AudioEdge(from: fadeNode ?? timeMap, to: gain))

                let pan = derivedNodeID(base: clip.id, salt: 0xA11D_1003)
                let combinedPan = max(-1.0, min(clipPanAtT + track.pan, 1.0))
                nodes[pan] = .pan(value: combinedPan)
                edges.append(AudioEdge(from: gain, to: pan))

                // Bus (reserved; keep graph shape stable for future routing)
                let bus = derivedNodeID(base: clip.id, salt: 0xA11D_1004)
                let busId = clip.outputBusId ?? track.outputBusId ?? track.id
                let role = clip.role ?? track.role
                nodes[bus] = .bus(id: busId, role: role)
                edges.append(AudioEdge(from: pan, to: bus))

                clipSnapshots.append(
                    AudioClipParameterSnapshot(
                        clipId: clip.id,
                        trackId: track.id,
                        busId: busId,
                        role: role,
                        isMuted: isMuted,
                        effectiveGain: effectiveGain,
                        effectivePan: combinedPan
                    )
                )

                if let lastBus {
                    // Deterministic chain to keep a single main output in Phase 1.
                    edges.append(AudioEdge(from: lastBus, to: bus))
                }
                lastBus = bus
            }
        }

        let snapshot = AudioGraphParameterSnapshot(
            timeSeconds: time,
            clips: clipSnapshots.sorted { $0.clipId.uuidString < $1.clipId.uuidString }
        )
        return AudioGraph(
            version: 1,
            nodes: nodes,
            edges: edges,
            outputs: AudioGraphOutputs(main: lastBus),
            parameterSnapshot: snapshot
        )
    }
}
