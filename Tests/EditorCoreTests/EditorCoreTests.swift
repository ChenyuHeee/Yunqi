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

    func testProjectEditorSpatialConformProjectDefaultUndoRedo() {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))

        XCTAssertEqual(editor.project.meta.spatialConformDefault, .fit)
        editor.setProjectSpatialConformDefault(.fill)
        XCTAssertEqual(editor.project.meta.spatialConformDefault, .fill)

        editor.undo()
        XCTAssertEqual(editor.project.meta.spatialConformDefault, .fit)

        editor.redo()
        XCTAssertEqual(editor.project.meta.spatialConformDefault, .fill)
    }

    func testProjectEditorSpatialConformClipOverrideSetClearUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")
        editor.addTrack(kind: .video)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 1)
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        func overrideValue() -> SpatialConform? {
            editor.project.timeline.tracks
                .flatMap { $0.clips }
                .first(where: { $0.id == clipId })?
                .spatialConformOverride
        }

        XCTAssertNil(overrideValue())

        try editor.setClipSpatialConformOverride(clipId: clipId, override: SpatialConform.none)
        XCTAssertEqual(overrideValue(), SpatialConform.none)

        editor.undo()
        XCTAssertNil(overrideValue())

        editor.redo()
        XCTAssertEqual(overrideValue(), SpatialConform.none)

        // Clear override (follow project)
        try editor.setClipSpatialConformOverride(clipId: clipId, override: nil)
        XCTAssertNil(overrideValue())

        editor.undo()
        XCTAssertEqual(overrideValue(), SpatialConform.none)
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

    func testAutomaticProjectFormatLocksOnFirstVideoClipUndoRedo() throws {
        var meta = ProjectMeta(name: "Demo", fps: 30)
        meta.formatPolicy = .automatic
        meta.renderSize = RenderSize(width: 1920, height: 1080)

        let editor = ProjectEditor(project: Project(meta: meta, timeline: Timeline(tracks: [Track(kind: .video)])))
        let assetId = editor.importAsset(path: "/tmp/video.mp4")

        try editor.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 0,
            sourceInSeconds: 0,
            durationSeconds: 1,
            speed: 1.0,
            autoLockProjectRenderSize: RenderSize(width: 1280, height: 720),
            autoLockProjectFPS: 59.94
        )

        XCTAssertEqual(editor.project.meta.formatPolicy, .custom)
        XCTAssertEqual(editor.project.meta.renderSize, RenderSize(width: 1280, height: 720))
        XCTAssertEqual(editor.project.meta.fps, 59.94, accuracy: 1e-9)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 1)

        editor.undo()
        XCTAssertEqual(editor.project.meta.formatPolicy, .automatic)
        XCTAssertEqual(editor.project.meta.renderSize, RenderSize(width: 1920, height: 1080))
        XCTAssertEqual(editor.project.meta.fps, 30, accuracy: 1e-9)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 0)

        editor.redo()
        XCTAssertEqual(editor.project.meta.formatPolicy, .custom)
        XCTAssertEqual(editor.project.meta.renderSize, RenderSize(width: 1280, height: 720))
        XCTAssertEqual(editor.project.meta.fps, 59.94, accuracy: 1e-9)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 1)
    }

    func testSpatialConformTransformFitCentersAndFits() {
        let natural = CGSize(width: 1920, height: 1080)
        let render = CGSize(width: 1000, height: 1000)
        let t = spatialConformTransform(
            naturalSize: natural,
            preferredTransform: .identity,
            renderSize: render,
            mode: .fit
        )

        let bbox = CGRect(origin: .zero, size: natural).applying(t)
        XCTAssertLessThanOrEqual(bbox.width, render.width + 0.5)
        XCTAssertLessThanOrEqual(bbox.height, render.height + 0.5)
        XCTAssertEqual(bbox.midX, render.width / 2.0, accuracy: 0.5)
        XCTAssertEqual(bbox.midY, render.height / 2.0, accuracy: 0.5)
    }

    func testSpatialConformTransformFillCentersAndCovers() {
        let natural = CGSize(width: 1920, height: 1080)
        let render = CGSize(width: 1000, height: 1000)
        let t = spatialConformTransform(
            naturalSize: natural,
            preferredTransform: .identity,
            renderSize: render,
            mode: .fill
        )

        let bbox = CGRect(origin: .zero, size: natural).applying(t)
        XCTAssertGreaterThanOrEqual(bbox.width + 0.5, render.width)
        XCTAssertGreaterThanOrEqual(bbox.height + 0.5, render.height)
        XCTAssertEqual(bbox.midX, render.width / 2.0, accuracy: 0.5)
        XCTAssertEqual(bbox.midY, render.height / 2.0, accuracy: 0.5)
    }

    func testSpatialConformTransformNoneCentersNoScale() {
        let natural = CGSize(width: 400, height: 300)
        let render = CGSize(width: 1000, height: 1000)
        let t = spatialConformTransform(
            naturalSize: natural,
            preferredTransform: .identity,
            renderSize: render,
            mode: .none
        )

        let bbox = CGRect(origin: .zero, size: natural).applying(t)
        XCTAssertEqual(bbox.width, natural.width, accuracy: 0.5)
        XCTAssertEqual(bbox.height, natural.height, accuracy: 0.5)
        XCTAssertEqual(bbox.midX, render.width / 2.0, accuracy: 0.5)
        XCTAssertEqual(bbox.midY, render.height / 2.0, accuracy: 0.5)
    }
}
