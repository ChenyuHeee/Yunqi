import EditorCore
import EditorEngine
import RenderEngine
import XCTest
import AudioEngine
import MediaIO
import Storage
@preconcurrency import AVFoundation

final class EditorEngineTests: XCTestCase {
    func testEditorSessionEditingAndSnapshot() async throws {
        let session = EditorSession(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = await session.importAsset(path: "/tmp/video.mp4")
        await session.addTrack(kind: .video)
        try await session.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1
        )

        let snap = await session.snapshot()
        XCTAssertEqual(snap.mediaAssets.count, 1)
        XCTAssertEqual(snap.timeline.tracks.count, 1)
        XCTAssertEqual(snap.timeline.tracks[0].clips.count, 1)
    }

    func testEditorSessionPlaybackStateTransitions() async {
        let session = EditorSession(project: Project(meta: ProjectMeta(name: "Demo", fps: 30)))
        await session.configurePlayback(engine: NoopRenderEngine())

        do {
            let state = await session.playbackState()
            XCTAssertEqual(state, .stopped)
        }

        await session.play()
        do {
            let state = await session.playbackState()
            XCTAssertEqual(state, .playing)
        }

        await session.pause()
        do {
            let state = await session.playbackState()
            XCTAssertEqual(state, .paused)
        }

        await session.stop()
        do {
            let state = await session.playbackState()
            XCTAssertEqual(state, .stopped)
        }
    }

    func testEditorSessionProjectChangesStreamEmits() async {
        let session = EditorSession(project: Project(meta: ProjectMeta(name: "Demo")))
        let stream = await session.projectChanges()
        var it = stream.makeAsyncIterator()

        let initial = await it.next()
        XCTAssertEqual(initial?.mediaAssets.count, 0)

        _ = await session.importAsset(path: "/tmp/video.mp4")
        let updated = await it.next()
        XCTAssertEqual(updated?.mediaAssets.count, 1)
    }

    func testTimelineEvaluatorEmptyProjectHasNoLayers() {
        let evaluator = TimelineEvaluator()
        let project = Project(meta: ProjectMeta(name: "Demo", fps: 30), timeline: Timeline(tracks: []))
        let graph = evaluator.evaluateRenderGraph(project: project, timeSeconds: 0)
        XCTAssertEqual(graph.renderSize, project.meta.renderSize)
        XCTAssertEqual(graph.video.layers.count, 0)
    }

    func testTimelineEvaluatorSelectsIntersectingClipAndMapsSourceTime() {
        let evaluator = TimelineEvaluator()

        var project = Project(meta: ProjectMeta(name: "Demo", fps: 30))
        let assetId = project.addAsset(path: "/tmp/video.mp4")
        project.addTrack(kind: .video)

        // Clip: timeline [10, 12), source starts at 5s, speed 2x.
        try? project.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 10,
            sourceInSeconds: 5,
            durationSeconds: 2,
            speed: 2.0
        )

        // t=11s is inside clip; local=1s => source=5+1*2=7s
        let g = evaluator.evaluateRenderGraph(project: project, timeSeconds: 11)
        XCTAssertEqual(g.video.layers.count, 1)
        XCTAssertEqual(g.video.layers[0].assetId, assetId)
        XCTAssertEqual(g.video.layers[0].sourceTimeSeconds, 7.0, accuracy: 1e-9)
        XCTAssertEqual(g.video.layers[0].spatialConform, project.meta.spatialConformDefault)

        // Outside should yield none.
        XCTAssertEqual(evaluator.evaluateRenderGraph(project: project, timeSeconds: 9.99).video.layers.count, 0)
        XCTAssertEqual(evaluator.evaluateRenderGraph(project: project, timeSeconds: 12.0).video.layers.count, 0)
    }

    func testTimelineEvaluatorAudioGraphSelectsIntersectingAudioClip() {
        let evaluator = TimelineEvaluator()

        var project = Project(meta: ProjectMeta(name: "Demo", fps: 30))
        let assetId = project.addAsset(path: "/tmp/audio.m4a")
        project.addTrack(kind: .audio)

        try? project.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 10,
            sourceInSeconds: 0,
            durationSeconds: 2,
            speed: 1.0
        )

        let g = evaluator.evaluateAudioGraph(project: project, timeSeconds: 11)
        XCTAssertNotNil(g.outputs.main)
        XCTAssertGreaterThan(g.nodes.count, 0)
    }

    func testTimelineEvaluatorAudioGraphEmitsSampleAccurateTimeMap() {
        let evaluator = TimelineEvaluator()

        var project = Project(meta: ProjectMeta(name: "Demo", fps: 30))
        let assetId = project.addAsset(path: "/tmp/audio.m4a")
        project.addTrack(kind: .audio)

        // timeline: [10, 12), source starts at 1s, speed 2x.
        // loop range in source seconds: [3, 4)
        try? project.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 10,
            sourceInSeconds: 1,
            durationSeconds: 2,
            speed: 2.0
        )
        project.timeline.tracks[0].clips[0].audioLoopRangeSeconds = AudioLoopRangeSeconds(startSeconds: 3, endSeconds: 4)

        // Evaluate at an intersecting time.
        let g = evaluator.evaluateAudioGraph(project: project, timeSeconds: 11)

        // Find the timeMap node.
        let timeMaps = g.nodes.values.compactMap { spec -> (AudioTimeStretchMode, AudioTimeMap)? in
            if case let .timeMap(mode, map) = spec { return (mode, map) }
            return nil
        }
        XCTAssertEqual(timeMaps.count, 1)

        let (mode, map) = timeMaps[0]
        XCTAssertEqual(mode, .keepPitch)
        XCTAssertEqual(map.sampleRate, 48_000, accuracy: 1e-12)

        XCTAssertEqual(map.timelineStartSampleTime, 480_000) // 10s * 48k
        XCTAssertEqual(map.timelineDurationSamples, 96_000)  // 2s * 48k
        XCTAssertEqual(map.sourceInSampleTime, 48_000)       // 1s * 48k
        XCTAssertEqual(map.speed, 2.0, accuracy: 1e-12)
        XCTAssertEqual(map.reverseMode, .mute)

        // Loop should be converted to samples.
        XCTAssertEqual(map.loop, AudioLoopRange(startSampleTime: 144_000, endSampleTime: 192_000))

        // Derived trim should match implied consumed source span.
        // durationSamples 96_000 at speed 2 => 192_000 source samples consumed.
        XCTAssertEqual(map.sourceTrim, AudioTrimRange(inSampleTime: 48_000, outSampleTime: 240_000))
    }

    func testTimelineEvaluatorAudioGraphHonorsClipMuteAndSolo() {
        let evaluator = TimelineEvaluator()

        var project = Project(meta: ProjectMeta(name: "Demo", fps: 30))
        let assetId = project.addAsset(path: "/tmp/audio.m4a")
        project.addTrack(kind: .audio)

        // Two overlapping clips, distinguishable by gain.
        try? project.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1,
            speed: 1.0
        )
        try? project.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1,
            speed: 1.0
        )

        project.timeline.tracks[0].clips[0].gain = 0.2
        project.timeline.tracks[0].clips[1].gain = 0.8
        project.timeline.tracks[0].clips[0].audioIsMuted = true

        // Without any solo: both clips contribute, but muted clip is silent via gain=0.
        let g = evaluator.evaluateAudioGraph(project: project, timeSeconds: 0.25)
        let gains = g.nodes.values.compactMap { spec -> Double? in
            if case let .gain(value) = spec { return value }
            return nil
        }
        XCTAssertTrue(gains.contains { abs($0 - 0.0) < 1e-12 })
        XCTAssertTrue(gains.contains { abs($0 - 0.8) < 1e-12 })

        // Enable solo for the second clip: only it contributes.
        project.timeline.tracks[0].clips[1].audioIsSolo = true
        let soloG = evaluator.evaluateAudioGraph(project: project, timeSeconds: 0.25)
        let soloGains = soloG.nodes.values.compactMap { spec -> Double? in
            if case let .gain(value) = spec { return value }
            return nil
        }
        XCTAssertFalse(soloGains.contains { abs($0 - 0.0) < 1e-12 })
        XCTAssertTrue(soloGains.contains { abs($0 - 0.8) < 1e-12 })
    }

    func testTimelineEvaluatorAudioGraphHonorsTrackSoloAndMute() {
        let evaluator = TimelineEvaluator()

        var project = Project(meta: ProjectMeta(name: "Demo", fps: 30))
        let assetId = project.addAsset(path: "/tmp/audio.m4a")
        project.addTrack(kind: .audio)
        project.addTrack(kind: .audio)

        try? project.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1,
            speed: 1.0
        )
        try? project.addClip(
            trackIndex: 1,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1,
            speed: 1.0
        )
        project.timeline.tracks[0].clips[0].gain = 0.3
        project.timeline.tracks[1].clips[0].gain = 0.7

        project.timeline.tracks[0].isSolo = true

        let soloTrackG = evaluator.evaluateAudioGraph(project: project, timeSeconds: 0.25)
        let gains = soloTrackG.nodes.values.compactMap { spec -> Double? in
            if case let .gain(value) = spec { return value }
            return nil
        }
        XCTAssertTrue(gains.contains { abs($0 - 0.3) < 1e-12 })
        XCTAssertFalse(gains.contains { abs($0 - 0.7) < 1e-12 })

        // Track mute should silence even if soloed.
        project.timeline.tracks[0].isMuted = true
        let mutedSoloTrackG = evaluator.evaluateAudioGraph(project: project, timeSeconds: 0.25)
        let mutedGains = mutedSoloTrackG.nodes.values.compactMap { spec -> Double? in
            if case let .gain(value) = spec { return value }
            return nil
        }
        XCTAssertTrue(mutedGains.contains { abs($0 - 0.0) < 1e-12 })
        XCTAssertFalse(mutedGains.contains { abs($0 - 0.7) < 1e-12 })
    }

    func testTimelineEvaluatorAudioGraphAppliesTrackVolumeAndPan() {
        let evaluator = TimelineEvaluator()

        var project = Project(meta: ProjectMeta(name: "Demo", fps: 30))
        let assetId = project.addAsset(path: "/tmp/audio.m4a")
        project.addTrack(kind: .audio)

        // Track controls should influence the node values.
        project.timeline.tracks[0].volume = 0.5
        project.timeline.tracks[0].pan = -0.3

        try? project.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1,
            speed: 1.0
        )
        project.timeline.tracks[0].clips[0].gain = 0.8
        project.timeline.tracks[0].clips[0].volume = 1.0
        project.timeline.tracks[0].clips[0].pan = 0.2

        let g = evaluator.evaluateAudioGraph(project: project, timeSeconds: 0.25)
        let gains = g.nodes.values.compactMap { spec -> Double? in
            if case let .gain(value) = spec { return value }
            return nil
        }
        let pans = g.nodes.values.compactMap { spec -> Double? in
            if case let .pan(value) = spec { return value }
            return nil
        }

        // effectiveGain = clip.gain * clip.volume * track.volume
        XCTAssertTrue(gains.contains { abs($0 - 0.4) < 1e-12 })
        // combinedPan = clamp(clip.pan + track.pan)
        XCTAssertTrue(pans.contains { abs($0 - (-0.1)) < 1e-12 })
    }

    func testTimelineEvaluatorAudioGraphEmitsFadeNodeWithSampleAccurateDurations() {
        let evaluator = TimelineEvaluator()

        var project = Project(meta: ProjectMeta(name: "Demo", fps: 30))
        let assetId = project.addAsset(path: "/tmp/audio.m4a")
        project.addTrack(kind: .audio)

        try? project.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 10,
            sourceInSeconds: 0,
            durationSeconds: 2,
            speed: 1.0
        )
        project.timeline.tracks[0].clips[0].fadeIn = AudioFade(durationSeconds: 0.5, shape: .linear)
        project.timeline.tracks[0].clips[0].fadeOut = AudioFade(durationSeconds: 0.25, shape: .equalPower)

        let g = evaluator.evaluateAudioGraph(project: project, timeSeconds: 11)
        let fades = g.nodes.values.compactMap { spec -> (AudioFadeSpec?, AudioFadeSpec?)? in
            if case let .fade(_, _, _, fadeIn, fadeOut) = spec { return (fadeIn, fadeOut) }
            return nil
        }
        XCTAssertEqual(fades.count, 1)

        let (fadeIn, fadeOut) = fades[0]
        XCTAssertEqual(fadeIn?.durationSamples, 24_000)
        XCTAssertEqual(fadeIn?.shape, .linear)
        XCTAssertEqual(fadeOut?.durationSamples, 12_000)
        XCTAssertEqual(fadeOut?.shape, .equalPower)
    }

    func testTimelineEvaluatorAudioGraphAppliesClipVolumePanAutomationAtTime() {
        let evaluator = TimelineEvaluator()

        var project = Project(meta: ProjectMeta(name: "Demo", fps: 30))
        let assetId = project.addAsset(path: "/tmp/audio.m4a")
        project.addTrack(kind: .audio)

        // Clip spans [0, 1). We'll evaluate at t=0.5 => clipLocal=0.5.
        try? project.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1,
            speed: 1.0
        )

        // volume: 1.0 at 0s -> 0.0 at 1s (linear) => 0.5 at 0.5s
        project.timeline.tracks[0].clips[0].volumeAutomation = AudioAutomationCurve(keyframes: [
            AudioAutomationKeyframe(timeSeconds: 0.0, value: 1.0, interpolation: .linear),
            AudioAutomationKeyframe(timeSeconds: 1.0, value: 0.0, interpolation: .linear)
        ])
        // pan: -1 at 0s -> +1 at 1s => 0 at 0.5s
        project.timeline.tracks[0].clips[0].panAutomation = AudioAutomationCurve(keyframes: [
            AudioAutomationKeyframe(timeSeconds: 0.0, value: -1.0, interpolation: .linear),
            AudioAutomationKeyframe(timeSeconds: 1.0, value: 1.0, interpolation: .linear)
        ])

        project.timeline.tracks[0].clips[0].gain = 1.0
        project.timeline.tracks[0].volume = 1.0
        project.timeline.tracks[0].pan = 0.0

        let g = evaluator.evaluateAudioGraph(project: project, timeSeconds: 0.5)

        let gains = g.nodes.values.compactMap { spec -> Double? in
            if case let .gain(value) = spec { return value }
            return nil
        }
        let pans = g.nodes.values.compactMap { spec -> Double? in
            if case let .pan(value) = spec { return value }
            return nil
        }

        XCTAssertTrue(gains.contains { abs($0 - 0.5) < 1e-12 })
        XCTAssertTrue(pans.contains { abs($0 - 0.0) < 1e-12 })
    }

    func testTimelineEvaluatorAudioGraphParameterSnapshotContainsEffectiveValues() {
        let evaluator = TimelineEvaluator()

        var project = Project(meta: ProjectMeta(name: "Demo", fps: 30))
        let assetId = project.addAsset(path: "/tmp/audio.m4a")
        project.addTrack(kind: .audio)
        project.addTrack(kind: .audio)

        try? project.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 1)
        try? project.addClip(trackIndex: 1, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 1)

        let clipA = project.timeline.tracks[0].clips[0].id
        let clipB = project.timeline.tracks[1].clips[0].id

        project.timeline.tracks[0].volume = 0.5
        project.timeline.tracks[0].pan = 0.1
        project.timeline.tracks[0].clips[0].gain = 0.8
        project.timeline.tracks[0].clips[0].volume = 1.0
        project.timeline.tracks[0].clips[0].pan = -0.2

        project.timeline.tracks[1].clips[0].gain = 1.0
        project.timeline.tracks[1].clips[0].audioIsSolo = true

        let g = evaluator.evaluateAudioGraph(project: project, timeSeconds: 0.25)
        let snap = g.parameterSnapshot
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.timeSeconds ?? -1, 0.25, accuracy: 1e-12)

        // Any solo exists => only solo clip should appear in snapshot.
        let clips = snap?.clips ?? []
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].clipId, clipB)

        // Disable solo to include both clips.
        project.timeline.tracks[1].clips[0].audioIsSolo = false
        let g2 = evaluator.evaluateAudioGraph(project: project, timeSeconds: 0.25)
        let clips2 = g2.parameterSnapshot?.clips ?? []
        XCTAssertEqual(clips2.count, 2)

        let a = clips2.first(where: { $0.clipId == clipA })
        XCTAssertEqual(a?.isMuted, false)
        // effectiveGain = 0.8 * 1.0 * 0.5 = 0.4
        XCTAssertEqual(a?.effectiveGain ?? -1, 0.4, accuracy: 1e-12)
        // effectivePan = clamp(-0.2 + 0.1) = -0.1
        XCTAssertEqual(a?.effectivePan ?? -2, -0.1, accuracy: 1e-12)
    }

    func testAudioGraphCompilerDeterministicPlanHash() throws {
        let compiler = AudioGraphCompiler()

        let id = AudioNodeID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let graphA = AudioGraph(
            version: 1,
            nodes: [id: .gain(value: 0.5)],
            edges: [],
            outputs: AudioGraphOutputs(main: id)
        )
        let graphB = graphA

        let planA = compiler.compile(graph: graphA, quality: .realtime)
        let planB = compiler.compile(graph: graphB, quality: .realtime)
        XCTAssertEqual(planA.planHash, planB.planHash)
        XCTAssertEqual(planA.stableHash64, planB.stableHash64)
        XCTAssertTrue(planA.diagnostics.isOK)
    }

    func testAudioGraphDumpDeterministicJSONForDifferentInsertionOrders() throws {
        let compiler = AudioGraphCompiler()

        let idA = AudioNodeID(UUID(uuidString: "00000000-0000-0000-0000-000000000111")!)
        let idB = AudioNodeID(UUID(uuidString: "00000000-0000-0000-0000-000000000112")!)

        var nodes1: [AudioNodeID: AudioNodeSpec] = [:]
        nodes1[idA] = .gain(value: 0.5)
        nodes1[idB] = .gain(value: 0.25)

        var nodes2: [AudioNodeID: AudioNodeSpec] = [:]
        nodes2[idB] = .gain(value: 0.25)
        nodes2[idA] = .gain(value: 0.5)

        let c1 = AudioClipParameterSnapshot(
            clipId: UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!,
            trackId: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            busId: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            role: AudioRole(name: "music"),
            isMuted: false,
            effectiveGain: 0.5,
            effectivePan: -0.25
        )
        let c2 = AudioClipParameterSnapshot(
            clipId: UUID(uuidString: "00000000-0000-0000-0000-00000000C002")!,
            trackId: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            busId: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            role: nil,
            isMuted: true,
            effectiveGain: 0,
            effectivePan: 0
        )
        let s1 = AudioGraphParameterSnapshot(timeSeconds: 0.25, clips: [c1, c2])
        let s2 = AudioGraphParameterSnapshot(timeSeconds: 0.25, clips: [c2, c1])

        let g1 = AudioGraph(
            version: 1,
            nodes: nodes1,
            edges: [],
            outputs: AudioGraphOutputs(main: idA),
            parameterSnapshot: s1
        )
        let g2 = AudioGraph(
            version: 1,
            nodes: nodes2,
            edges: [],
            outputs: AudioGraphOutputs(main: idA),
            parameterSnapshot: s2
        )

        let p1 = compiler.compile(graph: g1, quality: .realtime)
        let p2 = compiler.compile(graph: g2, quality: .realtime)
        XCTAssertEqual(p1.stableHash64, p2.stableHash64)

        let d1 = AudioGraphDump(graph: g1, plan: p1)
        let d2 = AudioGraphDump(graph: g2, plan: p2)

        let j1 = try d1.encodeDeterministicJSON(prettyPrinted: false)
        let j2 = try d2.encodeDeterministicJSON(prettyPrinted: false)
        XCTAssertEqual(j1, j2)
    }

    func testAudioGraphDumpJSONRoundtrip() throws {
        let compiler = AudioGraphCompiler()
        let id = AudioNodeID(UUID(uuidString: "00000000-0000-0000-0000-000000000221")!)
        let clip = AudioClipParameterSnapshot(
            clipId: UUID(uuidString: "00000000-0000-0000-0000-00000000C221")!,
            trackId: UUID(uuidString: "00000000-0000-0000-0000-000000000122")!,
            busId: UUID(uuidString: "00000000-0000-0000-0000-00000000B221")!,
            role: AudioRole(name: "dialogue"),
            isMuted: false,
            effectiveGain: 1.0,
            effectivePan: 0.0
        )
        let graph = AudioGraph(
            version: 1,
            nodes: [id: .gain(value: 1.0)],
            edges: [],
            outputs: AudioGraphOutputs(main: id),
            parameterSnapshot: AudioGraphParameterSnapshot(timeSeconds: 0.0, clips: [clip])
        )
        let plan = compiler.compile(graph: graph, quality: .realtime)
        let dump = AudioGraphDump(graph: graph, plan: plan)

        let data = try dump.encodeDeterministicJSON(prettyPrinted: false)
        let decoded = try JSONDecoder().decode(AudioGraphDump.self, from: data)
        XCTAssertEqual(decoded, dump)
    }

    func testAudioGraphCompilerMergesConsecutiveGainsInLinearChain() {
        let compiler = AudioGraphCompiler()

        let src = AudioNodeID(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let g1 = AudioNodeID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let g2 = AudioNodeID(UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)

        let graph = AudioGraph(
            version: 1,
            nodes: [
                src: .source(clipId: UUID(), assetId: UUID(), format: nil),
                g1: .gain(value: 0.5),
                g2: .gain(value: 0.25)
            ],
            edges: [
                AudioEdge(from: src, to: g1),
                AudioEdge(from: g1, to: g2)
            ],
            outputs: AudioGraphOutputs(main: g2)
        )

        let plan = compiler.compile(graph: graph, quality: .realtime)
        let plannedG2 = plan.ordered.first { $0.id == g2 }
        guard case let .gain(v)? = plannedG2?.spec else {
            XCTFail("Expected gain node")
            return
        }
        XCTAssertEqual(v, 0.125, accuracy: 1e-9)
        // g2 should now take src as input (since g1 is absorbed).
        XCTAssertEqual(plannedG2?.inputs, [src])
    }

    func testAudioGraphCompilerBindsSourceNodes() {
        struct Binder: AudioResourceBinder {
            func bindSource(
                clipId: UUID,
                assetId: UUID,
                formatHint: AudioSourceFormat?,
                quality: AudioRenderQuality
            ) -> AudioSourceHandle? {
                // Deterministic handle for test.
                AudioSourceHandle(id: assetId)
            }
        }

        let compiler = AudioGraphCompiler()
        let binder = Binder()

        let clipId = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let assetId = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let src = AudioNodeID(UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!)

        let graph = AudioGraph(
            version: 1,
            nodes: [
                src: .source(clipId: clipId, assetId: assetId, format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2))
            ],
            edges: [],
            outputs: AudioGraphOutputs(main: src)
        )

        let plan = compiler.compile(graph: graph, quality: .realtime, binder: binder)
        let planned = plan.ordered.first { $0.id == src }
        XCTAssertEqual(planned?.boundSource, AudioSourceHandle(id: assetId))
        XCTAssertTrue(plan.diagnostics.isOK)
    }

    func testAudioClockSampleTimeDeterministic() {
        let clock = AudioClock()
        XCTAssertEqual(clock.sampleTime(timelineSeconds: 0), 0)
        XCTAssertEqual(clock.sampleTime(timelineSeconds: 1.0), 48_000)
        XCTAssertEqual(clock.sampleTime(timelineSeconds: -1.0), 0)
        XCTAssertEqual(clock.timelineSeconds(sampleTime: 96_000), 2.0, accuracy: 1e-12)
    }

    func testMediaClockHostTimeSampleTimeConversions() {
        let clock = MediaClock(anchorHostTimeNanos: 1_000_000_000, anchorSampleTime: 0, sampleRate: 48_000)

        // +0.5s => 24_000 samples
        XCTAssertEqual(clock.sampleTime(hostTimeNanos: 1_500_000_000), 24_000)
        // +2.0s => 96_000 samples
        XCTAssertEqual(clock.sampleTime(hostTimeNanos: 3_000_000_000), 96_000)

        XCTAssertEqual(clock.hostTimeNanos(sampleTime: 24_000), 1_500_000_000)
        XCTAssertEqual(clock.hostTimeNanos(sampleTime: 96_000), 3_000_000_000)

        // Earlier than anchor clamps.
        XCTAssertEqual(clock.sampleTime(hostTimeNanos: 999_000_000), 0)
    }

    func testMediaClockLoopWrapping() {
        var clock = MediaClock(anchorHostTimeNanos: 0, anchorSampleTime: 0, sampleRate: 48_000)
        clock.setLoop(MediaLoopRange(startSampleTime: 10_000, endSampleTime: 20_000))

        // In range stays.
        XCTAssertEqual(clock.sampleTime(hostTimeNanos: 0), 10_000)
        XCTAssertEqual(clock.hostTimeNanos(sampleTime: 15_000), 312_500_000) // 15k/48k = 0.3125s

        // Sample time wraps.
        XCTAssertEqual(clock.hostTimeNanos(sampleTime: 20_000), clock.hostTimeNanos(sampleTime: 10_000))
        XCTAssertEqual(clock.hostTimeNanos(sampleTime: 25_000), clock.hostTimeNanos(sampleTime: 15_000))
    }

    func testAudioTimeMapReturnsNilOutsideTimelineRange() {
        let map = AudioTimeMap(
            sampleRate: 48_000,
            timelineStartSampleTime: 100,
            timelineDurationSamples: 10,
            sourceInSampleTime: 1_000,
            speed: 1.0,
            reverseMode: .mute
        )

        XCTAssertNil(map.sourceSampleTime(forTimelineSampleTime: 99))
        XCTAssertNotNil(map.sourceSampleTime(forTimelineSampleTime: 100))
        XCTAssertNotNil(map.sourceSampleTime(forTimelineSampleTime: 109))
        XCTAssertNil(map.sourceSampleTime(forTimelineSampleTime: 110))
    }

    func testAudioTimeMapForwardSpeed1Mapping() {
        let map = AudioTimeMap(
            sampleRate: 48_000,
            timelineStartSampleTime: 0,
            timelineDurationSamples: 4,
            sourceInSampleTime: 1_000,
            speed: 1.0,
            reverseMode: .mute
        )

        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 0), 1_000)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 1), 1_001)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 3), 1_003)
    }

    func testAudioTimeMapForwardSpeedHalfDeterministicRounding() {
        // dt=1 sample, speed=0.5 => 0.5 source samples, round(.toNearestOrAwayFromZero) => 1
        let map = AudioTimeMap(
            sampleRate: 48_000,
            timelineStartSampleTime: 0,
            timelineDurationSamples: 3,
            sourceInSampleTime: 1_000,
            speed: 0.5,
            reverseMode: .mute
        )

        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 0), 1_000)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 1), 1_001)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 2), 1_001)
    }

    func testAudioTimeMapReverseMappingOffByOneCorrect() {
        // timelineDuration=4 samples, speed=1 => source span length=4 samples
        // Reverse should map timeline 0 -> sourceIn+3, timeline 3 -> sourceIn
        let map = AudioTimeMap(
            sampleRate: 48_000,
            timelineStartSampleTime: 0,
            timelineDurationSamples: 4,
            sourceInSampleTime: 1_000,
            speed: 1.0,
            reverseMode: .roughReverse
        )

        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 0), 1_003)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 1), 1_002)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 3), 1_000)
    }

    func testAudioTimeMapLoopWrapsSourceSampleTime() {
        let map = AudioTimeMap(
            sampleRate: 48_000,
            timelineStartSampleTime: 0,
            timelineDurationSamples: 10,
            sourceInSampleTime: 10,
            speed: 1.0,
            reverseMode: .mute,
            loop: AudioLoopRange(startSampleTime: 10, endSampleTime: 13)
        )

        XCTAssertNil(map.sourceSampleTime(forTimelineSampleTime: 10))
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 0), 10)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 1), 11)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 2), 12)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 3), 10)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 4), 11)
    }

    func testAudioTimeMapSourceTrimFiltersOutOfRange() {
        let map = AudioTimeMap(
            sampleRate: 48_000,
            timelineStartSampleTime: 0,
            timelineDurationSamples: 5,
            sourceInSampleTime: 1_000,
            sourceTrim: AudioTrimRange(inSampleTime: 1_001, outSampleTime: 1_004),
            speed: 1.0,
            reverseMode: .mute
        )

        XCTAssertNil(map.sourceSampleTime(forTimelineSampleTime: 0)) // 1000 < trim.in
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 1), 1_001)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 3), 1_003)
        XCTAssertNil(map.sourceSampleTime(forTimelineSampleTime: 4)) // 1004 == trim.out
    }

    func testAudioTimeMapApplyingSlipShiftsSourceIn() {
        let map = AudioTimeMap(
            sampleRate: 48_000,
            timelineStartSampleTime: 0,
            timelineDurationSamples: 3,
            sourceInSampleTime: 100,
            speed: 1.0,
            reverseMode: .mute
        )

        let slipped = map.applyingSlip(offsetSamples: 10)
        XCTAssertEqual(map.sourceSampleTime(forTimelineSampleTime: 0), 100)
        XCTAssertEqual(slipped.sourceSampleTime(forTimelineSampleTime: 0), 110)
        XCTAssertEqual(slipped.sourceSampleTime(forTimelineSampleTime: 2), 112)
    }

    func testPlaybackSyncPolicyCodable() throws {
        let p: PlaybackSyncPolicy = .audioMaster
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PlaybackSyncPolicy.self, from: data)
        XCTAssertEqual(decoded, .audioMaster)
    }

    func testAudioRenderPlanBuildRuntimeGraph() throws {
        final class NoopRuntime: AudioNodeRuntime {
            func prepare(format: AudioSourceFormat, maxFrames: Int) throws {}
            func reset() {}
            func process(context: AudioProcessContext, frameCount: Int, pool: any AudioBufferPool) -> AudioBufferLease {
                pool.borrow(channelCount: format.channelCount, frameCount: frameCount)
            }

            private let format: AudioSourceFormat
            init(format: AudioSourceFormat) { self.format = format }
        }

        struct Factory: AudioRuntimeFactory {
            let format: AudioSourceFormat
            func makeRuntime(for plannedNode: AudioPlannedNode) throws -> any AudioNodeRuntime {
                NoopRuntime(format: format)
            }
        }

        let id = AudioNodeID(UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!)
        let plan = AudioRenderPlan(
            quality: .realtime,
            planHash: 1,
            stableHash64: 1,
            ordered: [AudioPlannedNode(id: id, spec: .gain(value: 1.0), inputs: [])],
            diagnostics: AudioGraphCompileDiagnostics()
        )

        let runtimeGraph = try plan.buildRuntimeGraph(factory: Factory(format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)))
        XCTAssertEqual(runtimeGraph.ordered.count, 1)
        let runtime = try XCTUnwrap(runtimeGraph.runtimes[id])

        // Ensure the pool/lease API is usable without allocations at borrow-time.
        let pool = FixedAudioBufferPool(capacityFrames: 512)
        let lease = runtime.process(
            context: AudioProcessContext(startSampleTime: 0, quality: .realtime),
            frameCount: 128,
            pool: pool
        )
        XCTAssertEqual(lease.buffer.frameCount, 128)
        pool.recycle(lease)
    }

    func testFixedAudioBufferPoolReusesBuffersWhenRecycled() {
        let pool = FixedAudioBufferPool(capacityFrames: 256, maxBuffersPerChannelCount: 8)
        var seen = Set<ObjectIdentifier>()

        for _ in 0..<200 {
            let lease = pool.borrow(channelCount: 2, frameCount: 128)
            seen.insert(ObjectIdentifier(lease.buffer))
            pool.recycle(lease)
        }

        // With immediate recycle, we should keep reusing the same buffer.
        XCTAssertEqual(seen.count, 1)
    }

    func testPreallocatedAudioBufferPoolBorrowRecycle() {
        let pool = PreallocatedAudioBufferPool(capacityFrames: 128, supportedChannelCounts: [2], buffersPerChannelCount: 2)
        let a = pool.borrow(channelCount: 2, frameCount: 64)
        XCTAssertEqual(a.buffer.frameCount, 64)
        let b = pool.borrow(channelCount: 2, frameCount: 64)
        XCTAssertEqual(b.buffer.frameCount, 64)
        pool.recycle(a)
        pool.recycle(b)
    }

    func testPreallocatedAudioBufferPoolUnderflowDiagnostics() {
        let pool = PreallocatedAudioBufferPool(capacityFrames: 128, supportedChannelCounts: [2], buffersPerChannelCount: 1)
        _ = pool.borrow(channelCount: 2, frameCount: 64)
        let exhausted = pool.borrow(channelCount: 2, frameCount: 64)
        XCTAssertEqual(exhausted.buffer.frameCount, 0)

        let d = pool.diagnosticsSnapshot()
        XCTAssertEqual(d.bufferPoolUnderflows, 1)
    }

    func testRealtimeAudioBufferPoolExhaustionUnderflowAndRecycle() {
        let pool = RealtimeAudioBufferPool(capacityFrames: 128, supportedChannelCounts: [2], buffersPerChannelCount: 2)

        let a = pool.borrow(channelCount: 2, frameCount: 64)
        let b = pool.borrow(channelCount: 2, frameCount: 64)
        XCTAssertEqual(a.buffer.frameCount, 64)
        XCTAssertEqual(b.buffer.frameCount, 64)

        let exhausted = pool.borrow(channelCount: 2, frameCount: 64)
        XCTAssertEqual(exhausted.buffer.frameCount, 0)

        let d1 = pool.diagnosticsSnapshot()
        XCTAssertEqual(d1.bufferPoolUnderflows, 1)

        pool.recycle(a)
        pool.recycle(b)

        let c = pool.borrow(channelCount: 2, frameCount: 32)
        XCTAssertEqual(c.buffer.frameCount, 32)
        pool.recycle(c)
    }

    func testAudioCallbackTimingCollectorBucketsAndReset() {
        let bounds: [UInt64] = [100, 200]
        let collector = AudioCallbackTimingCollector(
            snapshot: AudioCallbackTimingSnapshot(bucketUpperBoundsNanos: bounds)
        )

        collector.record(durationNanos: 50)   // <= 100 => bucket 0
        collector.record(durationNanos: 100)  // <= 100 => bucket 0
        collector.record(durationNanos: 150)  // <= 200 => bucket 1
        collector.record(durationNanos: 250)  // > 200  => bucket 2

        let snap = collector.snapshotOnly()
        XCTAssertEqual(snap.bucketUpperBoundsNanos, bounds)
        XCTAssertEqual(snap.bucketCounts, [2, 1, 1])

        let snap2 = collector.snapshotAndReset()
        XCTAssertEqual(snap2.bucketCounts, [2, 1, 1])

        let snap3 = collector.snapshotOnly()
        XCTAssertEqual(snap3.bucketCounts, [0, 0, 0])
    }

    func testAudioCacheMetricsCollectorHitMissAndReset() {
        let collector = AudioCacheMetricsCollector()

        collector.recordHit(kind: .pcm)
        collector.recordHit(kind: .pcm)
        collector.recordHit(kind: .waveform)
        collector.recordMiss(kind: .pcm)
        collector.recordMiss(kind: .analysis)

        let snap = collector.snapshotOnly()
        XCTAssertEqual(snap.hits, 3)
        XCTAssertEqual(snap.misses, 2)
        XCTAssertEqual(snap.hitsByKind[.pcm], 2)
        XCTAssertEqual(snap.hitsByKind[.waveform], 1)
        XCTAssertEqual(snap.missesByKind[.pcm], 1)
        XCTAssertEqual(snap.missesByKind[.analysis], 1)

        let snap2 = collector.snapshotAndReset()
        XCTAssertEqual(snap2.hits, 3)
        XCTAssertEqual(snap2.misses, 2)

        let snap3 = collector.snapshotOnly()
        XCTAssertEqual(snap3.hits, 0)
        XCTAssertEqual(snap3.misses, 0)
        XCTAssertTrue(snap3.hitsByKind.isEmpty)
        XCTAssertTrue(snap3.missesByKind.isEmpty)
    }

    func testAudioGoldenHashAndStatisticsDeterministic() throws {
        let format = AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
        // 4 frames, stereo interleaved.
        let pcm: [Float] = [
            0.0, 0.0,
            0.5, -0.5,
            1.0, -1.0,
            0.25, -0.25
        ]

        let h1 = AudioGolden.hash64(interleaved: pcm)
        let h2 = AudioGolden.hash64(interleaved: pcm)
        XCTAssertEqual(h1, h2)

        let stats = AudioGolden.statistics(interleaved: pcm)
        XCTAssertEqual(stats.peak, 1.0, accuracy: 1e-6)
        // RMS: sqrt(mean(x^2)) for all samples.
        // squares: 0,0,0.25,0.25,1,1,0.0625,0.0625 => sum=2.625 => mean=0.328125
        XCTAssertEqual(stats.rms, Float((0.328125).squareRoot()), accuracy: 1e-6)

        var pcm2 = pcm
        pcm2[2] = 0.50000006 // bitPattern change => hash should change
        let h3 = AudioGolden.hash64(interleaved: pcm2)
        XCTAssertNotEqual(h1, h3)

        let snap = AudioGolden.snapshot(format: format, frameCount: 4, interleaved: pcm)
        XCTAssertEqual(snap.algorithmVersion, AudioGolden.algorithmVersion)
        XCTAssertEqual(snap.format, format)
        XCTAssertEqual(snap.frameCount, 4)
        XCTAssertEqual(snap.stats.peak, 1.0, accuracy: 1e-6)

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(AudioPCMGoldenSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testGoldenAudioCaseStableKeyAndDeterministicJSON() throws {
        let format = AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
        let expected = AudioGolden.snapshot(format: format, frameCount: 0, interleaved: [])

        let project = Project(meta: ProjectMeta(name: "Golden", fps: 30))

        let c1 = GoldenAudioCase(
            name: "Case A",
            project: project,
            startSeconds: 0,
            durationSeconds: 1,
            quality: .realtime,
            outputFormat: format,
            expected: expected
        )

        let c2 = GoldenAudioCase(
            name: "Case A renamed", // should not affect key
            project: project,
            startSeconds: 0,
            durationSeconds: 1,
            quality: .realtime,
            outputFormat: format,
            expected: expected
        )

        XCTAssertEqual(c1.stableKey64, c2.stableKey64)
        XCTAssertEqual(c1.stableFileName, c2.stableFileName)

        let j1 = try c1.encodeDeterministicJSON(prettyPrinted: false)
        let j2 = try c1.encodeDeterministicJSON(prettyPrinted: false)
        XCTAssertEqual(j1, j2)

        let decoded = try JSONDecoder().decode(GoldenAudioCase.self, from: j1)
        XCTAssertEqual(decoded.stableKey64, c1.stableKey64)
        XCTAssertEqual(decoded.stableFileName, c1.stableFileName)
    }

    func testGoldenAudioStoreLoadsOrUpdatesOnDiskSnapshot() throws {
        final class DeterministicRenderer: OfflineAudioRenderer, @unchecked Sendable {
            func render(startSampleTime: Int64, frameCount: Int, format: AudioSourceFormat) throws -> AudioPCMBlock {
                let n = max(0, frameCount) * max(1, format.channelCount)
                let v = Float((abs(Int(startSampleTime)) % 7) + frameCount)
                return AudioPCMBlock(
                    channelCount: format.channelCount,
                    frameCount: frameCount,
                    interleaved: Array(repeating: v, count: n)
                )
            }
        }

        let renderer = DeterministicRenderer()
        let format = AudioSourceFormat(sampleRate: 48_000, channelCount: 2)

        // `expected` is not used for stable naming anymore, but kept for schema completeness.
        let placeholder = AudioGolden.snapshot(format: format, frameCount: 0, interleaved: [])
        let project = Project(meta: ProjectMeta(name: "GoldenStore", fps: 30))

        let c = GoldenAudioCase(
            name: "Golden store",
            project: project,
            startSeconds: 0.5,
            durationSeconds: 1.0 / 30.0,
            quality: .realtime,
            outputFormat: format,
            expected: placeholder
        )

        let actual = try GoldenAudioRunner.run(case: c, renderer: renderer)

        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let goldensDir = testDir.appendingPathComponent("Goldens", isDirectory: true)
        let url = GoldenAudioStore.goldenFileURL(baseURL: goldensDir, fileName: c.stableFileName)

        if GoldenAudioStore.shouldUpdateGoldens() {
            try GoldenAudioStore.saveSnapshot(actual, to: url, prettyPrinted: true)
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing golden file: \(url.path). Run with \(GoldenAudioStore.updateGoldensEnv)=1 to generate.")
            return
        }

        let expected = try GoldenAudioStore.loadSnapshot(from: url)
        XCTAssertEqual(expected, actual)
    }

    func testGoldenAudioRunnerComputesSampleTimeAndFrames() throws {
        final class CapturingRenderer: OfflineAudioRenderer, @unchecked Sendable {
            var lastStartSampleTime: Int64?
            var lastFrameCount: Int?
            var lastFormat: AudioSourceFormat?

            func render(startSampleTime: Int64, frameCount: Int, format: AudioSourceFormat) throws -> AudioPCMBlock {
                lastStartSampleTime = startSampleTime
                lastFrameCount = frameCount
                lastFormat = format
                // Return deterministic content that depends on inputs.
                // Interleaved length must match channelCount * frameCount.
                let n = max(0, frameCount) * max(1, format.channelCount)
                let v = Float((abs(Int(startSampleTime)) % 7) + frameCount)
                return AudioPCMBlock(channelCount: format.channelCount, frameCount: frameCount, interleaved: Array(repeating: v, count: n))
            }
        }

        let renderer = CapturingRenderer()
        let format = AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
        let expected = AudioGolden.snapshot(format: format, frameCount: 0, interleaved: [])
        let project = Project(meta: ProjectMeta(name: "Golden", fps: 30))

        let c = GoldenAudioCase(
            name: "Runner",
            project: project,
            startSeconds: 0.5,
            durationSeconds: 1.0 / 30.0,
            quality: .realtime,
            outputFormat: format,
            expected: expected
        )

        let snap = try GoldenAudioRunner.run(case: c, renderer: renderer)

        XCTAssertEqual(renderer.lastStartSampleTime, 24_000)
        XCTAssertEqual(renderer.lastFrameCount, 1_600)
        XCTAssertEqual(renderer.lastFormat, format)

        // Snapshot matches what AudioGolden would compute from renderer output.
        let n = 1_600 * 2
        let v = Float((abs(Int(24_000)) % 7) + 1_600)
        let expectedSnap = AudioGolden.snapshot(format: format, frameCount: 1_600, interleaved: Array(repeating: v, count: n))
        XCTAssertEqual(snap, expectedSnap)
    }

    func testRealtimeAudioRendererSetLoopDefaultImplementationCompiles() throws {
        struct Dummy: RealtimeAudioRenderer {
            func start() throws {}
            func stop() {}
            func setRate(_ rate: Double) { _ = rate }
            func seek(toSampleTime sampleTime: Int64) { _ = sampleTime }
            // Intentionally do not implement setLoop(_:) to ensure default is used.
        }

        let r: any RealtimeAudioRenderer = Dummy()
        r.setLoop(0..<48_000)
        r.setLoop(nil)
    }

    func testLinearAudioResamplerRealtimeNearestNeighbor() throws {
        let resampler = LinearAudioResampler()
        let input = AudioPCMBlock(channelCount: 1, frameCount: 4, interleaved: [0, 1, 2, 3])

        // Upsample 4 frames @ 4Hz to 8Hz => 8 frames.
        let out = try resampler.process(input: input, fromRate: 4, toRate: 8, quality: .realtime)
        XCTAssertEqual(out.channelCount, 1)
        XCTAssertEqual(out.frameCount, 8)

        // Realtime uses linear interpolation; spot-check a few points.
        XCTAssertEqual(out.interleaved[0], 0, accuracy: 1e-6)
        XCTAssertEqual(out.interleaved[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out.interleaved[2], 1, accuracy: 1e-6)
    }

    func testLinearAudioResamplerHighLinearInterpolationDeterministic() throws {
        let resampler = LinearAudioResampler()
        let inFrames = 256
        let input = AudioPCMBlock(channelCount: 1, frameCount: inFrames, interleaved: (0..<inFrames).map { Float($0) })

        let a = try resampler.process(input: input, fromRate: 4, toRate: 8, quality: .high)
        let b = try resampler.process(input: input, fromRate: 4, toRate: 8, quality: .high)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.frameCount, 512)

        // High uses windowed-sinc. Validate it behaves like a smooth upsampled ramp away from edges.
        // outFrame 256 -> inPos 128.0
        XCTAssertEqual(a.interleaved[256], 128, accuracy: 0.1)
        // outFrame 257 -> inPos 128.5
        XCTAssertEqual(a.interleaved[257], 128.5, accuracy: 0.1)

        // High should not exactly match realtime for most signals.
        let rt = try resampler.process(input: input, fromRate: 4, toRate: 8, quality: .realtime)
        XCTAssertNotEqual(rt, a)
    }

    func testAVFoundationAudioDecodeSourceReadsWAVAndSeeks() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("YunqiTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("decode-\(UUID().uuidString).wav")

        // Write a deterministic mono float32 WAV: samples are 0,1,2,...
        let sr: Double = 48_000
        let frames: AVAudioFrameCount = 64
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            buf.floatChannelData!.pointee[i] = Float(i)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buf)
        }

        let src = try await AVFoundationAudioDecodeSource(url: url)
        XCTAssertEqual(src.sourceFormat.sampleRate, sr, accuracy: 1e-9)
        XCTAssertEqual(src.sourceFormat.channelCount, 1)
        XCTAssertEqual(src.durationFrames, 64)

        // Read head.
        let head = try src.readPCM(startFrame: 0, frameCount: 8)
        XCTAssertEqual(head.frameCount, 8)
        XCTAssertEqual(head.interleaved, [0, 1, 2, 3, 4, 5, 6, 7])

        // Seek and read.
        let mid = try src.readPCM(startFrame: 10, frameCount: 5)
        XCTAssertEqual(mid.frameCount, 5)
        XCTAssertEqual(mid.interleaved, [10, 11, 12, 13, 14])
    }

    func testCachedAudioDecodeSourceDoesNotReuseAfterFileChange() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("YunqiTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let url = tmp.appendingPathComponent("decode-cache-\(UUID().uuidString).wav")
        let cacheDir = tmp.appendingPathComponent("PCMCache-\(UUID().uuidString)", isDirectory: true)
        let cache = AudioPCMCache(baseURL: cacheDir)

        let assetId = UUID()
        let clipId = UUID()

        func writeWav(startValue: Float) throws {
            let sr: Double = 48_000
            let frames: AVAudioFrameCount = 64
            let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buf.frameLength = frames
            for i in 0..<Int(frames) {
                buf.floatChannelData!.pointee[i] = startValue + Float(i)
            }

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]

            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buf)
        }

        // Initial content: 0,1,2,...
        try writeWav(startValue: 0)

        let upstream1 = try await AVFoundationAudioDecodeSource(url: url)
        let cached1 = CachedAudioDecodeSource(
            upstream: upstream1,
            cache: cache,
            assetId: assetId,
            clipId: clipId,
            planStableHash64: 0x1234,
            algorithmVersion: 1,
            assetURL: url
        )

        let a = try cached1.readPCM(startFrame: 0, frameCount: 8)
        XCTAssertEqual(a.interleaved, [0, 1, 2, 3, 4, 5, 6, 7])

        let before = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertGreaterThan(before.filter { $0.lastPathComponent.hasPrefix("pcm_\(assetId.uuidString)") }.count, 0)

        // Change file content; fingerprint should change, and cache should not reuse old data.
        // Small sleep to avoid pathological timestamp coalescing.
        usleep(10_000)
        try writeWav(startValue: 1000)

        let upstream2 = try await AVFoundationAudioDecodeSource(url: url)
        let cached2 = CachedAudioDecodeSource(
            upstream: upstream2,
            cache: cache,
            assetId: assetId,
            clipId: clipId,
            planStableHash64: 0x1234,
            algorithmVersion: 1,
            assetURL: url
        )

        let b = try cached2.readPCM(startFrame: 0, frameCount: 8)
        XCTAssertEqual(b.interleaved, [1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007])
    }
}
