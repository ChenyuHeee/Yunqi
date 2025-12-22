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

    func testProjectEditorRenameAssetUndoRedoAndDefaultName() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")

        let imported = try XCTUnwrap(editor.project.mediaAssets.first(where: { $0.id == assetId }))
        XCTAssertEqual(imported.displayName, "video.mp4")

        try editor.renameAsset(assetId: assetId, displayName: "Interview A")
        let renamed = try XCTUnwrap(editor.project.mediaAssets.first(where: { $0.id == assetId }))
        XCTAssertEqual(renamed.displayName, "Interview A")

        editor.undo()
        let undone = try XCTUnwrap(editor.project.mediaAssets.first(where: { $0.id == assetId }))
        XCTAssertEqual(undone.displayName, "video.mp4")

        editor.redo()
        let redone = try XCTUnwrap(editor.project.mediaAssets.first(where: { $0.id == assetId }))
        XCTAssertEqual(redone.displayName, "Interview A")
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

    func testProjectEditorSetClipVolumeUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")
        editor.addTrack(kind: .video)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 1)
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        // Default volume is 1.0
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].volume, 1.0, accuracy: 1e-9)

        try editor.setClipVolume(clipId: clipId, volume: 0.5)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].volume, 0.5, accuracy: 1e-9)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].volume, 1.0, accuracy: 1e-9)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].volume, 0.5, accuracy: 1e-9)
    }

    func testProjectEditorToggleTrackMuteSoloUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        editor.addTrack(kind: .video)
        editor.addTrack(kind: .audio)
        let trackA = editor.project.timeline.tracks[0]
        let trackB = editor.project.timeline.tracks[1]

        XCTAssertFalse(trackA.isMuted)
        XCTAssertFalse(trackA.isSolo)

        try editor.toggleTrackMute(trackId: trackA.id)
        XCTAssertTrue(editor.project.timeline.tracks[0].isMuted)
        editor.undo()
        XCTAssertFalse(editor.project.timeline.tracks[0].isMuted)
        editor.redo()
        XCTAssertTrue(editor.project.timeline.tracks[0].isMuted)

        try editor.toggleTrackSolo(trackId: trackB.id)
        XCTAssertTrue(editor.project.timeline.tracks[1].isSolo)
        editor.undo()
        XCTAssertFalse(editor.project.timeline.tracks[1].isSolo)
        editor.redo()
        XCTAssertTrue(editor.project.timeline.tracks[1].isSolo)
    }

    func testMoveClipAutoLanesToNewTrackOnOverlapUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")
        editor.addTrack(kind: .video)

        // Clip A: [0, 5)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 5, speed: 1)
        // Clip B: [6, 8)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 6, sourceInSeconds: 0, durationSeconds: 2, speed: 1)
        let clipBId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.last?.id)

        // Move B to start at 3s -> overlaps Clip A -> should auto-lane to a new video track.
        try editor.moveClip(clipId: clipBId, toStartSeconds: 3)

        XCTAssertEqual(editor.project.timeline.tracks.count, 2)
        XCTAssertEqual(editor.project.timeline.tracks[1].kind, .video)
        let moved = try XCTUnwrap(editor.project.timeline.tracks[1].clips.first(where: { $0.id == clipBId }))
        XCTAssertEqual(moved.timelineStartSeconds, 3, accuracy: 1e-9)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks.count, 1)
        let undone = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first(where: { $0.id == clipBId }))
        XCTAssertEqual(undone.timelineStartSeconds, 6, accuracy: 1e-9)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks.count, 2)
        let redone = try XCTUnwrap(editor.project.timeline.tracks[1].clips.first(where: { $0.id == clipBId }))
        XCTAssertEqual(redone.timelineStartSeconds, 3, accuracy: 1e-9)
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
