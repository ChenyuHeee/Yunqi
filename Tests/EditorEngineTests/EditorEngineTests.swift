import EditorCore
import EditorEngine
import RenderEngine
import XCTest

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
}
