import XCTest
@testable import EditorCore
import RenderEngine
import AudioEngine
import Storage
@preconcurrency import AVFoundation

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

    func testProjectEditorSlipClipUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/audio.m4a")
        editor.addTrack(kind: .audio)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 5, sourceInSeconds: 1, durationSeconds: 2)
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        func snapshot() -> (timelineStart: Double, sourceIn: Double, duration: Double) {
            let c = editor.project.timeline.tracks[0].clips[0]
            return (c.timelineStartSeconds, c.sourceInSeconds, c.durationSeconds)
        }

        XCTAssertEqual(snapshot().timelineStart, 5, accuracy: 1e-12)
        XCTAssertEqual(snapshot().sourceIn, 1, accuracy: 1e-12)
        XCTAssertEqual(snapshot().duration, 2, accuracy: 1e-12)

        try editor.slipClip(clipId: clipId, toSourceInSeconds: 3.5)
        XCTAssertEqual(snapshot().timelineStart, 5, accuracy: 1e-12)
        XCTAssertEqual(snapshot().sourceIn, 3.5, accuracy: 1e-12)
        XCTAssertEqual(snapshot().duration, 2, accuracy: 1e-12)

        editor.undo()
        XCTAssertEqual(snapshot().sourceIn, 1, accuracy: 1e-12)

        editor.redo()
        XCTAssertEqual(snapshot().sourceIn, 3.5, accuracy: 1e-12)
    }

    func testProjectEditorSetClipGainPanAndAudioModesUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/audio.m4a")
        editor.addTrack(kind: .audio)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 1)
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        // Defaults.
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].gain, 1.0, accuracy: 1e-12)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].pan, 0.0, accuracy: 1e-12)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioTimeStretchMode, .keepPitch)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioReversePlaybackMode, .mute)

        try editor.setClipGain(clipId: clipId, gain: 0.5)
        try editor.setClipPan(clipId: clipId, pan: -0.25)
        try editor.setClipAudioTimeStretchMode(clipId: clipId, mode: .varispeed)
        try editor.setClipAudioReversePlaybackMode(clipId: clipId, mode: .roughReverse)

        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].gain, 0.5, accuracy: 1e-12)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].pan, -0.25, accuracy: 1e-12)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioTimeStretchMode, .varispeed)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioReversePlaybackMode, .roughReverse)

        // Undo/redo should step through each change.
        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioReversePlaybackMode, .mute)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioTimeStretchMode, .keepPitch)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].pan, 0.0, accuracy: 1e-12)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].gain, 1.0, accuracy: 1e-12)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].gain, 0.5, accuracy: 1e-12)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].pan, -0.25, accuracy: 1e-12)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioTimeStretchMode, .varispeed)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioReversePlaybackMode, .roughReverse)
    }

    func testProjectEditorSetClipAudioMuteSoloUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/audio.m4a")
        editor.addTrack(kind: .audio)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 1)
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioIsMuted, false)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioIsSolo, false)

        try editor.setClipAudioMuted(clipId: clipId, isMuted: true)
        try editor.setClipAudioSolo(clipId: clipId, isSolo: true)

        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioIsMuted, true)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioIsSolo, true)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioIsSolo, false)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioIsMuted, false)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioIsMuted, true)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioIsSolo, true)
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

    func testProjectEditorSetClipAudioLoopRangeUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/audio.m4a")
        editor.addTrack(kind: .audio)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 1)
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        XCTAssertNil(editor.project.timeline.tracks[0].clips[0].audioLoopRangeSeconds)

        try editor.setClipAudioLoopRangeSeconds(clipId: clipId, loopRangeSeconds: AudioLoopRangeSeconds(startSeconds: 1.0, endSeconds: 2.0))
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioLoopRangeSeconds, AudioLoopRangeSeconds(startSeconds: 1.0, endSeconds: 2.0))

        editor.undo()
        XCTAssertNil(editor.project.timeline.tracks[0].clips[0].audioLoopRangeSeconds)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioLoopRangeSeconds, AudioLoopRangeSeconds(startSeconds: 1.0, endSeconds: 2.0))

        // Setting an empty range normalizes to nil.
        try editor.setClipAudioLoopRangeSeconds(clipId: clipId, loopRangeSeconds: AudioLoopRangeSeconds(startSeconds: 2.0, endSeconds: 2.0))
        XCTAssertNil(editor.project.timeline.tracks[0].clips[0].audioLoopRangeSeconds)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioLoopRangeSeconds, AudioLoopRangeSeconds(startSeconds: 1.0, endSeconds: 2.0))
    }

    func testProjectEditorSetClipFadeInOutUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/audio.m4a")
        editor.addTrack(kind: .audio)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 2)
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        XCTAssertNil(editor.project.timeline.tracks[0].clips[0].fadeIn)
        XCTAssertNil(editor.project.timeline.tracks[0].clips[0].fadeOut)

        try editor.setClipFadeIn(clipId: clipId, fade: AudioFade(durationSeconds: 0.5, shape: .linear))
        try editor.setClipFadeOut(clipId: clipId, fade: AudioFade(durationSeconds: 0.25, shape: .equalPower))

        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].fadeIn, AudioFade(durationSeconds: 0.5, shape: .linear))
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].fadeOut, AudioFade(durationSeconds: 0.25, shape: .equalPower))

        editor.undo()
        XCTAssertNil(editor.project.timeline.tracks[0].clips[0].fadeOut)

        editor.undo()
        XCTAssertNil(editor.project.timeline.tracks[0].clips[0].fadeIn)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].fadeIn, AudioFade(durationSeconds: 0.5, shape: .linear))

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].fadeOut, AudioFade(durationSeconds: 0.25, shape: .equalPower))
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

    func testProjectEditorSetTrackVolumePanUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        editor.addTrack(kind: .audio)
        let trackId = editor.project.timeline.tracks[0].id

        XCTAssertEqual(editor.project.timeline.tracks[0].volume, 1.0, accuracy: 1e-12)
        XCTAssertEqual(editor.project.timeline.tracks[0].pan, 0.0, accuracy: 1e-12)

        try editor.setTrackVolume(trackId: trackId, volume: 0.5)
        try editor.setTrackPan(trackId: trackId, pan: -0.25)

        XCTAssertEqual(editor.project.timeline.tracks[0].volume, 0.5, accuracy: 1e-12)
        XCTAssertEqual(editor.project.timeline.tracks[0].pan, -0.25, accuracy: 1e-12)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].pan, 0.0, accuracy: 1e-12)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].volume, 1.0, accuracy: 1e-12)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].volume, 0.5, accuracy: 1e-12)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].pan, -0.25, accuracy: 1e-12)
    }

        func testClipDecodeBackCompatDefaultsForAudioFields() throws {
                // Simulate older project files which only had MVP fields.
                let json = """
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "assetId": "00000000-0000-0000-0000-000000000002",
                    "timelineStartSeconds": 0,
                    "sourceInSeconds": 0,
                    "durationSeconds": 1,
                    "speed": 1,
                    "volume": 1
                }
                """

                let data = try XCTUnwrap(json.data(using: .utf8))
                let decoded = try JSONDecoder().decode(Clip.self, from: data)

                XCTAssertEqual(decoded.gain, 1.0, accuracy: 1e-9)
                XCTAssertEqual(decoded.pan, 0.0, accuracy: 1e-9)
                XCTAssertEqual(decoded.audioIsMuted, false)
                XCTAssertEqual(decoded.audioIsSolo, false)
                XCTAssertEqual(decoded.audioTimeStretchMode, .keepPitch)
                XCTAssertEqual(decoded.audioReversePlaybackMode, .mute)
                XCTAssertNil(decoded.audioLoopRangeSeconds)
                XCTAssertNil(decoded.role)
                XCTAssertNil(decoded.subrole)
                XCTAssertNil(decoded.outputBusId)
                XCTAssertNil(decoded.fadeIn)
                XCTAssertNil(decoded.fadeOut)
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

    func testAudioCacheKeyCodableRoundtrip() throws {
        let key = AudioCacheKey(
            assetId: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            clipId: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            planStableHash64: 123456789,
            algorithmVersion: 1,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
            assetFingerprint: "s123-m456"
        )

        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(AudioCacheKey.self, from: data)
        XCTAssertEqual(decoded, key)
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

final class WaveformCacheTests: XCTestCase {
    func testWaveformCacheComputesAndPersistsForWAV() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("YunqiTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let wav = tmp.appendingPathComponent("waveform-\(UUID().uuidString).wav")

        // Write deterministic mono float32 WAV.
        let sr: Double = 48_000
        let frames: AVAudioFrameCount = 4096
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            // Simple sine-ish pattern in [-1,1].
            let x = Double(i) / 64.0
            buf.floatChannelData!.pointee[i] = Float(sin(x))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        do {
            let file = try AVAudioFile(forWriting: wav, settings: settings)
            try file.write(from: buf)
        }

        let cacheDir = tmp.appendingPathComponent("Waveforms", isDirectory: true)
        let cache = WaveformCache(baseURL: cacheDir)
        let assetId = UUID()

        let a = try await cache.loadOrCompute(assetId: assetId, url: wav, startSeconds: 0, durationSeconds: 4096.0 / sr)
        let b = try await cache.loadOrCompute(assetId: assetId, url: wav, startSeconds: 0, durationSeconds: 4096.0 / sr)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.peak.count, 2048)
        XCTAssertEqual(a.rms.count, 2048)

        // Multi-resolution mip levels are persisted/loaded.
        XCTAssertNotNil(a.mips)
        XCTAssertGreaterThan(a.mips?.count ?? 0, 1)
        XCTAssertEqual(a.mips?.first?.count, 2048)
        XCTAssertEqual(a.mips?.last?.count, 1)

        let r = cache.resampled(a, desiredCount: 128)
        XCTAssertEqual(r.peak.count, 128)
        XCTAssertEqual(r.rms.count, 128)

        // Values are normalized.
        XCTAssertLessThanOrEqual(r.peak.max() ?? 0, 1.0001)
        XCTAssertLessThanOrEqual(r.rms.max() ?? 0, 1.0001)
        XCTAssertGreaterThanOrEqual(r.peak.min() ?? 0, -0.0001)
        XCTAssertGreaterThanOrEqual(r.rms.min() ?? 0, -0.0001)
    }

    func testWaveformCacheInvalidateRemovesDiskAndRebuilds() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("YunqiTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let wav = tmp.appendingPathComponent("waveform-invalidate-\(UUID().uuidString).wav")

        // Write deterministic mono float32 WAV.
        let sr: Double = 48_000
        let frames: AVAudioFrameCount = 2048
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            buf.floatChannelData!.pointee[i] = Float(sin(Double(i) / 32.0))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        do {
            let file = try AVAudioFile(forWriting: wav, settings: settings)
            try file.write(from: buf)
        }

        let cacheDir = tmp.appendingPathComponent("WaveformsInvalidate", isDirectory: true)
        let cache = WaveformCache(baseURL: cacheDir)
        let assetId = UUID()

        _ = try await cache.loadOrCompute(assetId: assetId, url: wav, startSeconds: 0, durationSeconds: 2048.0 / sr)
        let before = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        let prefix = "waveform_\(assetId.uuidString)"
        XCTAssertGreaterThan(before.filter { $0.lastPathComponent.hasPrefix(prefix) }.count, 0)

        cache.invalidate(assetId: assetId)
        let afterInvalidate = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(afterInvalidate.filter { $0.lastPathComponent.hasPrefix(prefix) }.count, 0)

        _ = try await cache.loadOrCompute(assetId: assetId, url: wav, startSeconds: 0, durationSeconds: 2048.0 / sr)
        let afterRebuild = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertGreaterThan(afterRebuild.filter { $0.lastPathComponent.hasPrefix(prefix) }.count, 0)
    }
}
