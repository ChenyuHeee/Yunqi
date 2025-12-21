import XCTest
@testable import EditorCore
import RenderEngine

final class EditorCoreTests: XCTestCase {
    func testCommandStackUndoRedo() {
        struct RenameProject: EditorCommand {
            let newName: String
            let oldName: String

            var name: String { "Rename Project" }

            func apply(to project: inout Project) {
                project.meta.name = newName
            }

            func revert(on project: inout Project) {
                project.meta.name = oldName
            }
        }

        var project = Project(meta: ProjectMeta(name: "A"))
        let stack = CommandStack()

        stack.execute(RenameProject(newName: "B", oldName: "A"), on: &project)
        XCTAssertEqual(project.meta.name, "B")

        stack.undo(on: &project)
        XCTAssertEqual(project.meta.name, "A")

        stack.redo(on: &project)
        XCTAssertEqual(project.meta.name, "B")
    }

    func testProjectEditorImportAssetAddTrackAddClip() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")
        editor.addTrack(kind: .video)
        try editor.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1.5,
            speed: 1
        )

        XCTAssertEqual(editor.project.mediaAssets.count, 1)
        XCTAssertEqual(editor.project.timeline.tracks.count, 1)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 1)
    }

    func testProjectEditorMoveClipUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")
        editor.addTrack(kind: .video)
        try editor.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1
        )
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        try editor.moveClip(clipId: clipId, toStartSeconds: 2)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].timelineStartSeconds, 2)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].timelineStartSeconds, 0)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].timelineStartSeconds, 2)
    }

    func testProjectEditorTrimClipLeftUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")
        editor.addTrack(kind: .video)
        try editor.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 5,
            sourceInSeconds: 0,
            durationSeconds: 4
        )
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        try editor.trimClip(
            clipId: clipId,
            newTimelineStartSeconds: 6,
            newSourceInSeconds: 1,
            newDurationSeconds: 3
        )

        let clipAfter = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first)
        XCTAssertEqual(clipAfter.timelineStartSeconds, 6)
        XCTAssertEqual(clipAfter.sourceInSeconds, 1)
        XCTAssertEqual(clipAfter.durationSeconds, 3)

        editor.undo()
        let clipUndo = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first)
        XCTAssertEqual(clipUndo.timelineStartSeconds, 5)
        XCTAssertEqual(clipUndo.sourceInSeconds, 0)
        XCTAssertEqual(clipUndo.durationSeconds, 4)

        editor.redo()
        let clipRedo = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first)
        XCTAssertEqual(clipRedo.timelineStartSeconds, 6)
        XCTAssertEqual(clipRedo.sourceInSeconds, 1)
        XCTAssertEqual(clipRedo.durationSeconds, 3)
    }

    func testProjectEditorTrimClipRightUndoRedoAndClamp() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")
        editor.addTrack(kind: .video)
        try editor.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 1,
            sourceInSeconds: 2,
            durationSeconds: 4
        )
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        try editor.trimClip(clipId: clipId, newDurationSeconds: 2.5)
        var clipAfter = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first)
        XCTAssertEqual(clipAfter.timelineStartSeconds, 1)
        XCTAssertEqual(clipAfter.sourceInSeconds, 2)
        XCTAssertEqual(clipAfter.durationSeconds, 2.5)

        editor.undo()
        clipAfter = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first)
        XCTAssertEqual(clipAfter.durationSeconds, 4)

        editor.redo()
        clipAfter = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first)
        XCTAssertEqual(clipAfter.durationSeconds, 2.5)

        // Clamp: duration should never be <= 0
        try editor.trimClip(clipId: clipId, newDurationSeconds: 0)
        clipAfter = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first)
        XCTAssertGreaterThan(clipAfter.durationSeconds, 0)
    }

    func testProjectEditorAddClipMissingAssetThrows() {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        editor.addTrack(kind: .video)

        XCTAssertThrowsError(
            try editor.addClip(
                trackIndex: 0,
                assetId: UUID(),
                timelineStartSeconds: 0,
                sourceInSeconds: 0,
                durationSeconds: 1
            )
        )
    }

    func testProjectEditorAddClipInvalidTrackThrows() {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")

        XCTAssertThrowsError(
            try editor.addClip(
                trackIndex: 99,
                assetId: assetId,
                timelineStartSeconds: 0,
                sourceInSeconds: 0,
                durationSeconds: 1
            )
        )
    }

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
}
