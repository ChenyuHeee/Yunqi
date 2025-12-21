import XCTest
@testable import EditorCore

final class SplitDeleteTests: XCTestCase {
    func testSplitClipBasicAndUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/a.mov")
        editor.addTrack(kind: .video)
        try editor.addClip(
            trackIndex: 0,
            assetId: assetId,
            timelineStartSeconds: 10,
            sourceInSeconds: 3,
            durationSeconds: 8,
            speed: 2
        )
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)

        // Split at playhead 13s -> offset 3s into clip.
        try editor.splitClip(clipId: clipId, at: 13)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 2)

        let left = editor.project.timeline.tracks[0].clips[0]
        let right = editor.project.timeline.tracks[0].clips[1]

        XCTAssertEqual(left.timelineStartSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(left.durationSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(left.sourceInSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(left.speed, 2, accuracy: 1e-9)

        XCTAssertEqual(right.timelineStartSeconds, 13, accuracy: 1e-9)
        XCTAssertEqual(right.durationSeconds, 5, accuracy: 1e-9)
        // Right sourceIn should advance by leftDisplay * speed
        XCTAssertEqual(right.sourceInSeconds, 3 + 3 * 2, accuracy: 1e-9)
        XCTAssertEqual(right.speed, 2, accuracy: 1e-9)
        XCTAssertNotEqual(right.id, clipId)

        // Undo: back to one clip
        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 1)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].id, clipId)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].durationSeconds, 8, accuracy: 1e-9)

        // Redo: split again
        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 2)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].durationSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[1].durationSeconds, 5, accuracy: 1e-9)
    }

    func testDeleteClipUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/a.mov")
        editor.addTrack(kind: .video)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 1)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 2, sourceInSeconds: 0, durationSeconds: 1)

        let clipAId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)
        let clipBId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.dropFirst().first?.id)
        try editor.deleteClip(clipId: clipBId)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 1)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].id, clipAId)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 2)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[1].id, clipBId)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 1)
    }

    func testRippleDeleteShiftsSubsequentClipsAndUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/a.mov")
        editor.addTrack(kind: .video)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 1)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 1, sourceInSeconds: 0, durationSeconds: 1)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 2, sourceInSeconds: 0, durationSeconds: 1)

        let clipA = try XCTUnwrap(editor.project.timeline.tracks[0].clips[safe: 0])
        let clipB = try XCTUnwrap(editor.project.timeline.tracks[0].clips[safe: 1])
        let clipC = try XCTUnwrap(editor.project.timeline.tracks[0].clips[safe: 2])

        try editor.rippleDeleteClips(clipIds: [clipB.id])
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 2)

        let remainingA = editor.project.timeline.tracks[0].clips[0]
        let remainingC = editor.project.timeline.tracks[0].clips[1]
        XCTAssertEqual(remainingA.id, clipA.id)
        XCTAssertEqual(remainingA.timelineStartSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(remainingC.id, clipC.id)
        XCTAssertEqual(remainingC.timelineStartSeconds, 1, accuracy: 1e-9)

        editor.undo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 3)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].id, clipA.id)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[1].id, clipB.id)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[2].id, clipC.id)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[2].timelineStartSeconds, 2, accuracy: 1e-9)

        editor.redo()
        XCTAssertEqual(editor.project.timeline.tracks[0].clips.count, 2)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[1].id, clipC.id)
        XCTAssertEqual(editor.project.timeline.tracks[0].clips[1].timelineStartSeconds, 1, accuracy: 1e-9)
    }

    func testRippleDeleteRangeSplitsClipAndShiftsLaterClipsUndoRedo() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/a.mov")
        editor.addTrack(kind: .video)

        // One long clip that spans the whole range.
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 10, speed: 1)
        // A later clip that should shift left by (7-3)=4s.
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 12, sourceInSeconds: 0, durationSeconds: 2, speed: 1)

        let beforeClips = editor.project.timeline.tracks[0].clips.sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
        XCTAssertEqual(beforeClips.count, 2)
        XCTAssertEqual(beforeClips[0].timelineStartSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(beforeClips[0].durationSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(beforeClips[1].timelineStartSeconds, 12, accuracy: 1e-9)
        XCTAssertEqual(beforeClips[1].durationSeconds, 2, accuracy: 1e-9)
        editor.rippleDeleteRange(inSeconds: 3, outSeconds: 7)

        XCTAssertTrue(editor.canUndo)
        XCTAssertEqual(editor.undoActionName, "Ripple Delete Range")

        let clips = editor.project.timeline.tracks[0].clips.sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
        XCTAssertEqual(clips.count, 3)

        // Left piece: 0..3
        XCTAssertEqual(clips[0].timelineStartSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(clips[0].durationSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(clips[0].sourceInSeconds, 0, accuracy: 1e-9)

        // Right piece: originally 7..10, should move to 3..6
        XCTAssertEqual(clips[1].timelineStartSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(clips[1].durationSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(clips[1].sourceInSeconds, 7, accuracy: 1e-9)
        XCTAssertNotEqual(clips[1].id, clips[0].id)

        // Later clip shifts from 12 -> 8
        XCTAssertEqual(clips[2].timelineStartSeconds, 8, accuracy: 1e-9)
        XCTAssertEqual(clips[2].durationSeconds, 2, accuracy: 1e-9)

        editor.undo()
        let undone = editor.project.timeline.tracks[0].clips.sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
        XCTAssertEqual(undone.count, 2)
        XCTAssertEqual(undone[0].timelineStartSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(undone[0].durationSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(undone[1].timelineStartSeconds, 12, accuracy: 1e-9)
        XCTAssertEqual(undone[1].durationSeconds, 2, accuracy: 1e-9)

        editor.redo()
        let clips2 = editor.project.timeline.tracks[0].clips.sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
        XCTAssertEqual(clips2.count, 3)
        XCTAssertEqual(clips2[0].timelineStartSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(clips2[1].timelineStartSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(clips2[2].timelineStartSeconds, 8, accuracy: 1e-9)
    }

    func testRippleDeleteRangeAppliesAcrossTracks() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/a.mov")
        editor.addTrack(kind: .video)
        editor.addTrack(kind: .audio)

        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 0, sourceInSeconds: 0, durationSeconds: 2)
        try editor.addClip(trackIndex: 1, assetId: assetId, timelineStartSeconds: 5, sourceInSeconds: 0, durationSeconds: 1)

        editor.rippleDeleteRange(inSeconds: 1, outSeconds: 4) // shift by 3

        let v = editor.project.timeline.tracks[0].clips
        let a = editor.project.timeline.tracks[1].clips
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(a.count, 1)

        // Video clip overlaps range: keep left piece 0..1
        XCTAssertEqual(v[0].timelineStartSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(v[0].durationSeconds, 1, accuracy: 1e-9)

        // Audio clip starts at 5, should shift to 2
        XCTAssertEqual(a[0].timelineStartSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(a[0].durationSeconds, 1, accuracy: 1e-9)
    }

    func testSplitClipInvalidTimeThrows() throws {
        let editor = ProjectEditor(project: Project(meta: ProjectMeta(name: "Demo")))
        let assetId = editor.importAsset(path: "/tmp/a.mov")
        editor.addTrack(kind: .video)
        try editor.addClip(trackIndex: 0, assetId: assetId, timelineStartSeconds: 10, sourceInSeconds: 0, durationSeconds: 5)
        let clipId = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first?.id)
        XCTAssertThrowsError(try editor.splitClip(clipId: clipId, at: 10))
        XCTAssertThrowsError(try editor.splitClip(clipId: clipId, at: 15))
        XCTAssertThrowsError(try editor.splitClip(clipId: clipId, at: 100))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
