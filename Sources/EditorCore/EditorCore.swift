import Foundation
import RenderEngine

public struct ProjectMeta: Codable, Sendable {
    public var name: String
    public var createdAt: Date
    public var fps: Double

    public init(name: String, createdAt: Date = Date(), fps: Double = 30.0) {
        self.name = name
        self.createdAt = createdAt
        self.fps = fps
    }
}

public struct Project: Codable, Sendable {
    public var meta: ProjectMeta
    public var mediaAssets: [MediaAssetRecord]
    public var timeline: Timeline

    public init(meta: ProjectMeta, mediaAssets: [MediaAssetRecord] = [], timeline: Timeline = Timeline()) {
        self.meta = meta
        self.mediaAssets = mediaAssets
        self.timeline = timeline
    }
}

public struct MediaAssetRecord: Codable, Sendable {
    public var id: UUID
    public var originalPath: String
    public var displayName: String
    public var importedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case originalPath
        case displayName
        case importedAt
    }

    public init(id: UUID = UUID(), originalPath: String, displayName: String? = nil, importedAt: Date = Date()) {
        self.id = id
        self.originalPath = originalPath
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? displayName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.defaultDisplayName(forOriginalPath: originalPath)
        self.importedAt = importedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        originalPath = try c.decode(String.self, forKey: .originalPath)
        importedAt = try c.decode(Date.self, forKey: .importedAt)

        let decoded = try c.decodeIfPresent(String.self, forKey: .displayName)
        let trimmed = decoded?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            displayName = trimmed
        } else {
            displayName = Self.defaultDisplayName(forOriginalPath: originalPath)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(originalPath, forKey: .originalPath)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(importedAt, forKey: .importedAt)
    }

    private static func defaultDisplayName(forOriginalPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if !name.isEmpty { return name }
        return path
    }
}

public struct Timeline: Codable, Sendable {
    public var tracks: [Track]

    public init(tracks: [Track] = []) {
        self.tracks = tracks
    }
}

public extension Project {
    mutating func addAsset(path: String, id: UUID = UUID()) -> UUID {
        let record = MediaAssetRecord(id: id, originalPath: path)
        mediaAssets.append(record)
        return record.id
    }

    mutating func addTrack(kind: TrackKind) {
        timeline.tracks.append(Track(kind: kind))
    }

    mutating func addClip(
        trackIndex: Int,
        assetId: UUID,
        timelineStartSeconds: Double,
        sourceInSeconds: Double,
        durationSeconds: Double,
        speed: Double = 1.0
    ) throws {
        guard timeline.tracks.indices.contains(trackIndex) else {
            throw ProjectEditError.invalidTrackIndex(trackIndex)
        }
        let clip = Clip(
            assetId: assetId,
            timelineStartSeconds: timelineStartSeconds,
            sourceInSeconds: sourceInSeconds,
            durationSeconds: durationSeconds,
            speed: speed
        )
        timeline.tracks[trackIndex].clips.append(clip)
    }
}

public enum ProjectEditError: Error, CustomStringConvertible, Sendable {
    case invalidTrackIndex(Int)
    case missingAsset(UUID)
    case missingClip(UUID)
    case missingTrack(UUID)
    case invalidSplitTime(clipId: UUID, timeSeconds: Double)
    case splitTooSmall(clipId: UUID, timeSeconds: Double)

    public var description: String {
        switch self {
        case let .invalidTrackIndex(index):
            return "Invalid track index: \(index)"
        case let .missingAsset(id):
            return "Missing asset: \(id.uuidString)"
        case let .missingClip(id):
            return "Missing clip: \(id.uuidString)"
        case let .missingTrack(id):
            return "Missing track: \(id.uuidString)"
        case let .invalidSplitTime(clipId, timeSeconds):
            return String(format: "Invalid split time: clip=%@ t=%.3f", clipId.uuidString, timeSeconds)
        case let .splitTooSmall(clipId, timeSeconds):
            return String(format: "Split results too small: clip=%@ t=%.3f", clipId.uuidString, timeSeconds)
        }
    }
}

// MARK: - Playback (Scheduler Skeleton)

public enum PlaybackState: Sendable {
    case stopped
    case playing
    case paused
}

public actor PlaybackController {
    public typealias ProjectSnapshotProvider = @Sendable () async -> Project
    public typealias FrameHandler = @Sendable (RenderedFrame) -> Void

    private let projectSnapshot: ProjectSnapshotProvider
    private let engine: any RenderEngine
    private let onFrame: FrameHandler?

    private var state: PlaybackState = .stopped
    private var currentTimeSeconds: Double = 0
    private var playbackTask: Task<Void, Never>?

    public init(
        projectSnapshot: @escaping ProjectSnapshotProvider,
        engine: any RenderEngine,
        onFrame: FrameHandler? = nil
    ) {
        self.projectSnapshot = projectSnapshot
        self.engine = engine
        self.onFrame = onFrame
    }

    public func getState() -> PlaybackState { state }
    public func getCurrentTimeSeconds() -> Double { currentTimeSeconds }

    public func prepare() throws {
        try engine.prepare()
    }

    public func seek(to timeSeconds: Double) {
        currentTimeSeconds = max(0, timeSeconds)
    }

    public func play(fps: Double? = nil) {
        guard state != .playing else { return }
        state = .playing

        playbackTask?.cancel()
        playbackTask = Task {
            let snapshot = await projectSnapshot()
            let timelineFPS = max(1, snapshot.meta.fps)
            let effectiveFPS = max(1, fps ?? timelineFPS)
            let dt = 1.0 / effectiveFPS

            while !Task.isCancelled {
                let frame = (try? engine.renderFrame(RenderRequest(timeSeconds: currentTimeSeconds, quality: .realtime)))
                if let frame {
                    onFrame?(frame)
                }
                currentTimeSeconds += dt
                let nanos = UInt64(dt * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    public func pause() {
        guard state == .playing else { return }
        state = .paused
        playbackTask?.cancel()
        playbackTask = nil
    }

    public func stop() {
        state = .stopped
        playbackTask?.cancel()
        playbackTask = nil
        currentTimeSeconds = 0
    }
}

// MARK: - ProjectEditor (Core API)

public final class ProjectEditor {
    public private(set) var project: Project
    private let commandStack: CommandStack

    public init(project: Project) {
        self.project = project
        self.commandStack = CommandStack()
    }

    public var canUndo: Bool { commandStack.canUndo }
    public var canRedo: Bool { commandStack.canRedo }

    public var undoActionName: String? { commandStack.undoActionName }
    public var redoActionName: String? { commandStack.redoActionName }

    public func execute(_ command: any EditorCommand) {
        commandStack.execute(command, on: &project)
    }

    public func undo() {
        commandStack.undo(on: &project)
    }

    public func redo() {
        commandStack.redo(on: &project)
    }

    @discardableResult
    public func importAsset(path: String, id: UUID = UUID()) -> UUID {
        let command = ImportAssetCommand(assetId: id, path: path)
        execute(command)
        return id
    }

    public func renameAsset(assetId: UUID, displayName: String) throws {
        guard let assetIndex = project.mediaAssets.firstIndex(where: { $0.id == assetId }) else {
            throw ProjectEditError.missingAsset(assetId)
        }

        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let oldName = project.mediaAssets[assetIndex].displayName
        let newName = trimmed
        guard oldName != newName else { return }

        execute(SetAssetDisplayNameCommand(assetId: assetId, oldName: oldName, newName: newName))
    }

    public func addTrack(kind: TrackKind) {
        execute(AddTrackCommand(kind: kind))
    }

    public func addClip(
        trackIndex: Int,
        assetId: UUID,
        timelineStartSeconds: Double,
        sourceInSeconds: Double,
        durationSeconds: Double,
        speed: Double = 1.0
    ) throws {
        guard project.mediaAssets.contains(where: { $0.id == assetId }) else {
            throw ProjectEditError.missingAsset(assetId)
        }
        guard project.timeline.tracks.indices.contains(trackIndex) else {
            throw ProjectEditError.invalidTrackIndex(trackIndex)
        }
        let command = AddClipCommand(
            trackIndex: trackIndex,
            assetId: assetId,
            timelineStartSeconds: timelineStartSeconds,
            sourceInSeconds: sourceInSeconds,
            durationSeconds: durationSeconds,
            speed: speed
        )
        execute(command)
    }

    public func moveClip(clipId: UUID, toStartSeconds: Double) throws {
        try moveClipsWithAutoLane([(clipId: clipId, startSeconds: toStartSeconds)], commandName: "Move Clip")
    }

    public func moveClips(_ moves: [(clipId: UUID, startSeconds: Double)]) throws {
        guard !moves.isEmpty else { return }
        try moveClipsWithAutoLane(moves, commandName: "Move Clips")
    }

    private func moveClipsWithAutoLane(_ moves: [(clipId: UUID, startSeconds: Double)], commandName: String) throws {
        guard !moves.isEmpty else { return }

        let uniqueMoves: [(clipId: UUID, startSeconds: Double)] = {
            // If a clip appears multiple times, keep the last provided target.
            var dict: [UUID: Double] = [:]
            for (id, s) in moves { dict[id] = s }
            return dict
                .map { ($0.key, $0.value) }
                .sorted { $0.0.uuidString < $1.0.uuidString }
        }()

        let before = project
        var after = project

        let movingIds = Set(uniqueMoves.map { $0.clipId })

        // Capture the moving clips and their original track kind.
        struct MovePayload {
            let clip: Clip
            let originalTrackKind: TrackKind
            let originalTrackIndex: Int
            let targetStartSeconds: Double
        }

        var payloads: [UUID: MovePayload] = [:]
        payloads.reserveCapacity(uniqueMoves.count)

        for (clipId, startSeconds) in uniqueMoves {
            let located = try locateClipIndexed(clipId: clipId)
            let kind = project.timeline.tracks[located.trackIndex].kind
            payloads[clipId] = MovePayload(
                clip: located.clip,
                originalTrackKind: kind,
                originalTrackIndex: located.trackIndex,
                targetStartSeconds: max(0, startSeconds)
            )
        }

        // Remove moving clips from all tracks first.
        for tIndex in after.timeline.tracks.indices {
            after.timeline.tracks[tIndex].clips.removeAll { movingIds.contains($0.id) }
        }

        func overlaps(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Bool {
            let eps = 1e-9
            return a0 < b1 - eps && a1 > b0 + eps
        }

        func trackHasRoom(trackIndex: Int, startSeconds: Double, durationSeconds: Double) -> Bool {
            guard after.timeline.tracks.indices.contains(trackIndex) else { return false }
            let clips = after.timeline.tracks[trackIndex].clips
            let a0 = startSeconds
            let a1 = startSeconds + max(0, durationSeconds)
            for c in clips {
                let b0 = c.timelineStartSeconds
                let b1 = c.timelineStartSeconds + c.durationSeconds
                if overlaps(a0, a1, b0, b1) { return false }
            }
            return true
        }

        func insertClipSorted(trackIndex: Int, clip: Clip) {
            var clips = after.timeline.tracks[trackIndex].clips
            let idx = clips.firstIndex {
                if abs($0.timelineStartSeconds - clip.timelineStartSeconds) > 1e-9 {
                    return $0.timelineStartSeconds > clip.timelineStartSeconds
                }
                return $0.id.uuidString > clip.id.uuidString
            } ?? clips.count
            clips.insert(clip, at: idx)
            after.timeline.tracks[trackIndex].clips = clips
        }

        // Greedy lane assignment per clip.
        for (clipId, _) in uniqueMoves {
            guard let payload = payloads[clipId] else { continue }
            let start = payload.targetStartSeconds

            var moved = payload.clip
            moved.timelineStartSeconds = start

            let duration = moved.durationSeconds
            let kind = payload.originalTrackKind

            // Candidate tracks: original first, then other same-kind tracks.
            var candidates: [Int] = []
            if after.timeline.tracks.indices.contains(payload.originalTrackIndex), after.timeline.tracks[payload.originalTrackIndex].kind == kind {
                candidates.append(payload.originalTrackIndex)
            }
            for idx in after.timeline.tracks.indices {
                if after.timeline.tracks[idx].kind == kind, !candidates.contains(idx) {
                    candidates.append(idx)
                }
            }

            if let targetIndex = candidates.first(where: { trackHasRoom(trackIndex: $0, startSeconds: start, durationSeconds: duration) }) {
                insertClipSorted(trackIndex: targetIndex, clip: moved)
            } else {
                // No room: create a new same-kind track and place it there.
                after.addTrack(kind: kind)
                let newTrackIndex = max(0, after.timeline.tracks.count - 1)
                insertClipSorted(trackIndex: newTrackIndex, clip: moved)
            }
        }

        execute(ProjectSnapshotCommand(name: commandName, before: before, after: after))
    }

    public func trimClip(
        clipId: UUID,
        newTimelineStartSeconds: Double? = nil,
        newSourceInSeconds: Double? = nil,
        newDurationSeconds: Double? = nil
    ) throws {
        let (trackId, old) = try locateClipFull(clipId: clipId)

        let start = max(0, newTimelineStartSeconds ?? old.timelineStartSeconds)
        let sourceIn = max(0, newSourceInSeconds ?? old.sourceInSeconds)
        let duration = max(ProjectEditorConstants.minClipDurationSeconds, newDurationSeconds ?? old.durationSeconds)

        let command = TrimClipCommand(
            trackId: trackId,
            clipId: clipId,
            oldTimelineStartSeconds: old.timelineStartSeconds,
            oldSourceInSeconds: old.sourceInSeconds,
            oldDurationSeconds: old.durationSeconds,
            newTimelineStartSeconds: start,
            newSourceInSeconds: sourceIn,
            newDurationSeconds: duration
        )
        execute(command)
    }

    public func deleteClip(clipId: UUID) throws {
        let located = try locateClipIndexed(clipId: clipId)
        let command = DeleteClipCommand(trackId: located.trackId, clipIndex: located.clipIndex, removed: located.clip)
        execute(command)
    }

    public func deleteClips(clipIds: [UUID]) throws {
        let unique = Array(Set(clipIds))
        guard !unique.isEmpty else { return }

        var removed: [DeleteClipsCommand.Removed] = []
        removed.reserveCapacity(unique.count)
        for id in unique {
            let located = try locateClipIndexed(clipId: id)
            removed.append(.init(trackId: located.trackId, clipIndex: located.clipIndex, clip: located.clip))
        }

        execute(DeleteClipsCommand(removed: removed))
    }

    /// Ripple delete: delete the clips and shift subsequent clips on the same track left
    /// by the cumulative duration of deleted clips that come before them.
    ///
    /// This keeps the operation as a single undo/redo step.
    public func rippleDeleteClips(clipIds: [UUID]) throws {
        let unique = Array(Set(clipIds))
        guard !unique.isEmpty else { return }

        var removed: [RippleDeleteClipsCommand.Removed] = []
        removed.reserveCapacity(unique.count)

        for id in unique {
            let located = try locateClipIndexed(clipId: id)
            removed.append(.init(trackId: located.trackId, clipIndex: located.clipIndex, clip: located.clip))
        }

        // Precompute moves for stable redo.
        let removedByTrack = Dictionary(grouping: removed, by: { $0.trackId })
        var moves: [RippleDeleteClipsCommand.MoveItem] = []

        for (trackId, removedItems) in removedByTrack {
            guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { continue }
            let track = project.timeline.tracks[trackIndex]

            let deletedIds = Set(removedItems.map { $0.clip.id })
            let deletedClipsSorted = removedItems.map { $0.clip }.sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
            let deletedDurationById: [UUID: Double] = Dictionary(uniqueKeysWithValues: deletedClipsSorted.map { ($0.id, $0.durationSeconds) })

            // Iterate clips in timeline order, accumulating the shift as we pass deleted clips.
            let sortedClips = track.clips.sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
            var cumulativeShift: Double = 0
            for clip in sortedClips {
                if deletedIds.contains(clip.id) {
                    cumulativeShift += deletedDurationById[clip.id] ?? clip.durationSeconds
                    continue
                }
                guard cumulativeShift > 0 else { continue }
                let oldStart = clip.timelineStartSeconds
                let newStart = max(0, oldStart - cumulativeShift)
                if abs(newStart - oldStart) > 1e-12 {
                    moves.append(.init(trackId: trackId, clipId: clip.id, oldStartSeconds: oldStart, newStartSeconds: newStart))
                }
            }
        }

        execute(RippleDeleteClipsCommand(removed: removed, moves: moves))
    }

    /// Ripple delete a time range across the whole timeline.
    ///
    /// The operation is modeled as: split clips at range boundaries (if needed),
    /// delete clips that fall inside the range, then shift everything after the
    /// range left by (out - in). Kept as a single undo/redo step.
    public func rippleDeleteRange(inSeconds: Double, outSeconds: Double) {
        let lo = max(0, min(inSeconds, outSeconds))
        let hi = max(0, max(inSeconds, outSeconds))
        guard hi - lo > 1e-9 else { return }

        let before = project
        let after = Self.projectByRippleDeletingRange(before, inSeconds: lo, outSeconds: hi)
        execute(RippleDeleteRangeCommand(before: before, after: after))
    }

    private static func projectByRippleDeletingRange(_ project: Project, inSeconds: Double, outSeconds: Double) -> Project {
        let d = outSeconds - inSeconds
        guard d > 0 else { return project }

        var out = project

        for tIndex in out.timeline.tracks.indices {
            let oldClips = out.timeline.tracks[tIndex].clips
            var newClips: [Clip] = []
            newClips.reserveCapacity(oldClips.count)

            for clip in oldClips {
                let start = clip.timelineStartSeconds
                let end = clip.timelineStartSeconds + clip.durationSeconds

                // Fully before range.
                if end <= inSeconds + 1e-12 {
                    newClips.append(clip)
                    continue
                }

                // Fully after range.
                if start >= outSeconds - 1e-12 {
                    var shifted = clip
                    shifted.timelineStartSeconds = max(0, shifted.timelineStartSeconds - d)
                    newClips.append(shifted)
                    continue
                }

                // Overlap with range: keep the left piece (trim) and/or right piece (split).
                if start < inSeconds - 1e-12 {
                    let leftDur = inSeconds - start
                    if leftDur >= ProjectEditorConstants.minClipDurationSeconds {
                        var left = clip
                        left.durationSeconds = leftDur
                        newClips.append(left)
                    }
                }

                if end > outSeconds + 1e-12 {
                    let rightDur = end - outSeconds
                    if rightDur >= ProjectEditorConstants.minClipDurationSeconds {
                        var right = clip
                        right.id = UUID()
                        right.timelineStartSeconds = max(0, outSeconds - d)

                        let speed = max(0.0001, clip.speed)
                        right.sourceInSeconds = clip.sourceInSeconds + (outSeconds - start) * speed
                        right.durationSeconds = rightDur
                        newClips.append(right)
                    }
                }
            }

            // Keep deterministic order.
            newClips.sort {
                if $0.timelineStartSeconds != $1.timelineStartSeconds {
                    return $0.timelineStartSeconds < $1.timelineStartSeconds
                }
                return $0.id.uuidString < $1.id.uuidString
            }

            out.timeline.tracks[tIndex].clips = newClips
        }

        return out
    }

    public func splitClip(clipId: UUID, at timeSeconds: Double) throws {
        let located = try locateClipIndexed(clipId: clipId)
        let clip = located.clip
        let start = clip.timelineStartSeconds
        let end = clip.timelineStartSeconds + clip.durationSeconds
        // Snap split time to the nearest frame to avoid sub-frame boundaries.
        // Sub-frame splits can cause tiny composition gaps/overlaps -> flashes in preview/export.
        let t = quantizeToFrame(timeSeconds)

        // Must split strictly inside clip bounds.
        guard t > start + 1e-9, t < end - 1e-9 else {
            throw ProjectEditError.invalidSplitTime(clipId: clipId, timeSeconds: t)
        }

        let leftDisplay = t - start
        let rightDisplay = end - t
        if leftDisplay < ProjectEditorConstants.minClipDurationSeconds || rightDisplay < ProjectEditorConstants.minClipDurationSeconds {
            throw ProjectEditError.splitTooSmall(clipId: clipId, timeSeconds: t)
        }

        let command = SplitClipCommand(
            trackId: located.trackId,
            clipIndex: located.clipIndex,
            original: clip,
            splitTimeSeconds: t
        )
        execute(command)
    }

    /// Split (blade) multiple clips at the given timeline time as a single undo/redo step.
    ///
    /// Clips that cannot be split at the given time (outside bounds or too-small result)
    /// are ignored.
    public func splitClips(clipIds: [UUID], at timeSeconds: Double) {
        let unique = Array(Set(clipIds))
        guard !unique.isEmpty else { return }

        let t = quantizeToFrame(timeSeconds)

        let before = project
        var after = project

        // Keep a deterministic processing order for stable results.
        let ordered: [UUID] = unique.sorted { $0.uuidString < $1.uuidString }
        var didAnySplit = false
        for id in ordered {
            if Self.splitClipInProject(&after, clipId: id, splitTimeSeconds: t) {
                didAnySplit = true
            }
        }
        guard didAnySplit else { return }

        let name = ordered.count == 1 ? "Split Clip" : "Split Clips"
        execute(ProjectSnapshotCommand(name: name, before: before, after: after))
    }

    private static func splitClipInProject(_ project: inout Project, clipId: UUID, splitTimeSeconds t: Double) -> Bool {
        // Locate clip by id.
        for trackIndex in project.timeline.tracks.indices {
            if let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipId }) {
                let clip = project.timeline.tracks[trackIndex].clips[clipIndex]
                let start = clip.timelineStartSeconds
                let end = clip.timelineStartSeconds + clip.durationSeconds

                // Must split strictly inside clip bounds.
                guard t > start + 1e-9, t < end - 1e-9 else { return false }

                let leftDisplay = t - start
                let rightStart = start + leftDisplay
                let rightDisplay = end - rightStart
                guard leftDisplay >= ProjectEditorConstants.minClipDurationSeconds,
                      rightDisplay >= ProjectEditorConstants.minClipDurationSeconds
                else { return false }

                let speed = clip.speed

                var left = clip
                left.durationSeconds = leftDisplay

                var right = clip
                right.id = UUID()
                right.timelineStartSeconds = rightStart
                right.sourceInSeconds = clip.sourceInSeconds + leftDisplay * max(0.0001, speed)
                right.durationSeconds = rightDisplay

                project.timeline.tracks[trackIndex].clips[clipIndex] = left
                project.timeline.tracks[trackIndex].clips.insert(right, at: clipIndex + 1)
                return true
            }
        }
        return false
    }

    private func quantizeToFrame(_ seconds: Double) -> Double {
        let fps = max(1.0, project.meta.fps)
        let frame = 1.0 / fps
        guard frame.isFinite, frame > 0, seconds.isFinite else { return seconds }
        return (seconds / frame).rounded() * frame
    }

    public func setClipVolume(clipId: UUID, volume: Double) throws {
        let (trackId, clip) = try locateClipFull(clipId: clipId)
        let newVolume = max(0, min(volume, 2.0))
        let command = SetClipVolumeCommand(
            trackId: trackId,
            clipId: clipId,
            oldVolume: clip.volume,
            newVolume: newVolume
        )
        execute(command)
    }

    public func toggleTrackMute(trackId: UUID) throws {
        let trackIndex = try locateTrackIndex(trackId: trackId)
        let old = project.timeline.tracks[trackIndex].isMuted
        execute(SetTrackMuteCommand(trackId: trackId, oldIsMuted: old, newIsMuted: !old))
    }

    public func toggleTrackSolo(trackId: UUID) throws {
        let trackIndex = try locateTrackIndex(trackId: trackId)
        let old = project.timeline.tracks[trackIndex].isSolo
        execute(SetTrackSoloCommand(trackId: trackId, oldIsSolo: old, newIsSolo: !old))
    }

    private func locateClip(clipId: UUID) throws -> (trackId: UUID, startSeconds: Double) {
        for track in project.timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                return (track.id, clip.timelineStartSeconds)
            }
        }
        throw ProjectEditError.missingClip(clipId)
    }

    private func locateClipFull(clipId: UUID) throws -> (trackId: UUID, clip: Clip) {
        for track in project.timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                return (track.id, clip)
            }
        }
        throw ProjectEditError.missingClip(clipId)
    }

    private func locateClipIndexed(clipId: UUID) throws -> (trackId: UUID, trackIndex: Int, clipIndex: Int, clip: Clip) {
        for (tIndex, track) in project.timeline.tracks.enumerated() {
            if let cIndex = track.clips.firstIndex(where: { $0.id == clipId }) {
                return (track.id, tIndex, cIndex, track.clips[cIndex])
            }
        }
        throw ProjectEditError.missingClip(clipId)
    }

    private func locateTrackIndex(trackId: UUID) throws -> Int {
        guard let idx = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else {
            throw ProjectEditError.missingTrack(trackId)
        }
        return idx
    }
}

private struct ProjectSnapshotCommand: EditorCommand {
    let name: String
    let before: Project
    let after: Project

    func apply(to project: inout Project) {
        project = after
    }

    func revert(on project: inout Project) {
        project = before
    }
}

private enum ProjectEditorConstants {
    static let minClipDurationSeconds: Double = 0.05
}

private struct DeleteClipCommand: EditorCommand {
    let trackId: UUID
    let clipIndex: Int
    let removed: Clip

    var name: String { "Delete Clip" }

    func apply(to project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        guard project.timeline.tracks[trackIndex].clips.indices.contains(clipIndex) else { return }
        // Defensive: ensure the clip still matches.
        if project.timeline.tracks[trackIndex].clips[clipIndex].id != removed.id {
            // Fallback: remove by id.
            project.timeline.tracks[trackIndex].clips.removeAll { $0.id == removed.id }
            return
        }
        project.timeline.tracks[trackIndex].clips.remove(at: clipIndex)
    }

    func revert(on project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        var clips = project.timeline.tracks[trackIndex].clips
        if clipIndex <= clips.count {
            clips.insert(removed, at: clipIndex)
        } else {
            clips.append(removed)
        }
        project.timeline.tracks[trackIndex].clips = clips
    }
}

private struct SplitClipCommand: EditorCommand {
    let trackId: UUID
    let clipIndex: Int
    let original: Clip
    let splitTimeSeconds: Double

    // Right clip id is fixed so redo keeps identity stable.
    let rightClipId: UUID = UUID()

    var name: String { "Split Clip" }

    func apply(to project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        guard project.timeline.tracks[trackIndex].clips.indices.contains(clipIndex) else { return }
        guard project.timeline.tracks[trackIndex].clips[clipIndex].id == original.id else {
            // Fallback: find by id.
            guard let idx = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == original.id }) else { return }
            return applyAtResolvedIndex(project: &project, trackIndex: trackIndex, resolvedClipIndex: idx)
        }
        applyAtResolvedIndex(project: &project, trackIndex: trackIndex, resolvedClipIndex: clipIndex)
    }

    private func applyAtResolvedIndex(project: inout Project, trackIndex: Int, resolvedClipIndex: Int) {
        let clip = project.timeline.tracks[trackIndex].clips[resolvedClipIndex]
        let start = clip.timelineStartSeconds
        let end = clip.timelineStartSeconds + clip.durationSeconds
        let t = splitTimeSeconds
        if !(t > start + 1e-9 && t < end - 1e-9) { return }

        let leftDisplay = t - start
        // IMPORTANT: derive the right start from (start + leftDisplay) so the boundary is exactly consistent
        // with the left clip end when recomputed later.
        let rightStart = start + leftDisplay
        let rightDisplay = end - rightStart
        if leftDisplay < ProjectEditorConstants.minClipDurationSeconds || rightDisplay < ProjectEditorConstants.minClipDurationSeconds { return }

        let speed = clip.speed

        var left = clip
        left.durationSeconds = leftDisplay

        var right = clip
        right.id = rightClipId
        right.timelineStartSeconds = rightStart
        right.sourceInSeconds = clip.sourceInSeconds + leftDisplay * max(0.0001, speed)
        right.durationSeconds = rightDisplay

        project.timeline.tracks[trackIndex].clips[resolvedClipIndex] = left
        project.timeline.tracks[trackIndex].clips.insert(right, at: resolvedClipIndex + 1)
    }

    func revert(on project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        // Remove the right clip if present, then restore the original clip.
        project.timeline.tracks[trackIndex].clips.removeAll { $0.id == rightClipId }
        if let idx = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == original.id }) {
            project.timeline.tracks[trackIndex].clips[idx] = original
        } else {
            // If original missing, re-insert.
            var clips = project.timeline.tracks[trackIndex].clips
            if clipIndex <= clips.count {
                clips.insert(original, at: clipIndex)
            } else {
                clips.append(original)
            }
            project.timeline.tracks[trackIndex].clips = clips
        }
    }
}

private struct SetClipVolumeCommand: EditorCommand {
    let trackId: UUID
    let clipId: UUID
    let oldVolume: Double
    let newVolume: Double

    var name: String { "Set Clip Volume" }

    func apply(to project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipId }) else { return }
        project.timeline.tracks[trackIndex].clips[clipIndex].volume = newVolume
    }

    func revert(on project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipId }) else { return }
        project.timeline.tracks[trackIndex].clips[clipIndex].volume = oldVolume
    }
}

private struct SetTrackMuteCommand: EditorCommand {
    let trackId: UUID
    let oldIsMuted: Bool
    let newIsMuted: Bool

    var name: String { newIsMuted ? "Mute Track" : "Unmute Track" }

    func apply(to project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        project.timeline.tracks[trackIndex].isMuted = newIsMuted
    }

    func revert(on project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        project.timeline.tracks[trackIndex].isMuted = oldIsMuted
    }
}

private struct SetTrackSoloCommand: EditorCommand {
    let trackId: UUID
    let oldIsSolo: Bool
    let newIsSolo: Bool

    var name: String { newIsSolo ? "Solo Track" : "Unsolo Track" }

    func apply(to project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        project.timeline.tracks[trackIndex].isSolo = newIsSolo
    }

    func revert(on project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        project.timeline.tracks[trackIndex].isSolo = oldIsSolo
    }
}

private struct ImportAssetCommand: EditorCommand {
    let assetId: UUID
    let path: String

    var name: String { "Import Asset" }

    func apply(to project: inout Project) {
        _ = project.addAsset(path: path, id: assetId)
    }

    func revert(on project: inout Project) {
        project.mediaAssets.removeAll { $0.id == assetId }
    }
}

private struct SetAssetDisplayNameCommand: EditorCommand {
    let assetId: UUID
    let oldName: String
    let newName: String

    var name: String { "Rename Asset" }

    func apply(to project: inout Project) {
        guard let idx = project.mediaAssets.firstIndex(where: { $0.id == assetId }) else { return }
        project.mediaAssets[idx].displayName = newName
    }

    func revert(on project: inout Project) {
        guard let idx = project.mediaAssets.firstIndex(where: { $0.id == assetId }) else { return }
        project.mediaAssets[idx].displayName = oldName
    }
}

private struct AddTrackCommand: EditorCommand {
    let kind: TrackKind

    var name: String { "Add Track" }

    func apply(to project: inout Project) {
        project.addTrack(kind: kind)
    }

    func revert(on project: inout Project) {
        _ = project.timeline.tracks.popLast()
    }
}

private struct AddClipCommand: EditorCommand {
    let trackIndex: Int
    let assetId: UUID
    let timelineStartSeconds: Double
    let sourceInSeconds: Double
    let durationSeconds: Double
    let speed: Double

    var name: String { "Add Clip" }

    func apply(to project: inout Project) {
        // Preconditions (trackIndex/assetId validity) are checked by ProjectEditor.
        let clip = Clip(
            assetId: assetId,
            timelineStartSeconds: timelineStartSeconds,
            sourceInSeconds: sourceInSeconds,
            durationSeconds: durationSeconds,
            speed: speed
        )
        project.timeline.tracks[trackIndex].clips.append(clip)
    }

    func revert(on project: inout Project) {
        guard project.timeline.tracks.indices.contains(trackIndex) else { return }
        _ = project.timeline.tracks[trackIndex].clips.popLast()
    }
}

private struct MoveClipCommand: EditorCommand {
    let trackId: UUID
    let clipId: UUID
    let oldStartSeconds: Double
    let newStartSeconds: Double

    var name: String { "Move Clip" }

    func apply(to project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipId }) else { return }
        project.timeline.tracks[trackIndex].clips[clipIndex].timelineStartSeconds = newStartSeconds
    }

    func revert(on project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipId }) else { return }
        project.timeline.tracks[trackIndex].clips[clipIndex].timelineStartSeconds = oldStartSeconds
    }
}

private struct MoveClipsCommand: EditorCommand {
    struct Item: Sendable {
        let trackId: UUID
        let clipId: UUID
        let oldStartSeconds: Double
        let newStartSeconds: Double
    }

    let items: [Item]

    var name: String { "Move Clips" }

    func apply(to project: inout Project) {
        for item in items {
            guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == item.trackId }) else { continue }
            guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == item.clipId }) else { continue }
            project.timeline.tracks[trackIndex].clips[clipIndex].timelineStartSeconds = item.newStartSeconds
        }
    }

    func revert(on project: inout Project) {
        // Reverse order for safety (not strictly required for simple field set).
        for item in items.reversed() {
            guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == item.trackId }) else { continue }
            guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == item.clipId }) else { continue }
            project.timeline.tracks[trackIndex].clips[clipIndex].timelineStartSeconds = item.oldStartSeconds
        }
    }
}

private struct DeleteClipsCommand: EditorCommand {
    struct Removed: Sendable {
        let trackId: UUID
        let clipIndex: Int
        let clip: Clip
    }

    let removed: [Removed]

    var name: String { "Delete Clips" }

    func apply(to project: inout Project) {
        let ids = Set(removed.map { $0.clip.id })
        guard !ids.isEmpty else { return }

        for tIndex in project.timeline.tracks.indices {
            project.timeline.tracks[tIndex].clips.removeAll { ids.contains($0.id) }
        }
    }

    func revert(on project: inout Project) {
        // Re-insert clips per track in ascending index order.
        let grouped = Dictionary(grouping: removed, by: { $0.trackId })
        for (trackId, items) in grouped {
            guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { continue }
            var clips = project.timeline.tracks[trackIndex].clips

            for item in items.sorted(by: { $0.clipIndex < $1.clipIndex }) {
                let idx = min(max(0, item.clipIndex), clips.count)
                clips.insert(item.clip, at: idx)
            }

            project.timeline.tracks[trackIndex].clips = clips
        }
    }
}

private struct RippleDeleteClipsCommand: EditorCommand {
    struct Removed: Sendable {
        let trackId: UUID
        let clipIndex: Int
        let clip: Clip
    }

    struct MoveItem: Sendable {
        let trackId: UUID
        let clipId: UUID
        let oldStartSeconds: Double
        let newStartSeconds: Double
    }

    let removed: [Removed]
    let moves: [MoveItem]

    var name: String { "Ripple Delete Clips" }

    func apply(to project: inout Project) {
        let removedIds = Set(removed.map { $0.clip.id })
        if !removedIds.isEmpty {
            for tIndex in project.timeline.tracks.indices {
                project.timeline.tracks[tIndex].clips.removeAll { removedIds.contains($0.id) }
            }
        }

        for item in moves {
            guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == item.trackId }) else { continue }
            guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == item.clipId }) else { continue }
            project.timeline.tracks[trackIndex].clips[clipIndex].timelineStartSeconds = item.newStartSeconds
        }
    }

    func revert(on project: inout Project) {
        for item in moves.reversed() {
            guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == item.trackId }) else { continue }
            guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == item.clipId }) else { continue }
            project.timeline.tracks[trackIndex].clips[clipIndex].timelineStartSeconds = item.oldStartSeconds
        }

        // Re-insert removed clips per track in ascending index order.
        let grouped = Dictionary(grouping: removed, by: { $0.trackId })
        for (trackId, items) in grouped {
            guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { continue }
            var clips = project.timeline.tracks[trackIndex].clips
            for item in items.sorted(by: { $0.clipIndex < $1.clipIndex }) {
                let idx = min(max(0, item.clipIndex), clips.count)
                clips.insert(item.clip, at: idx)
            }
            project.timeline.tracks[trackIndex].clips = clips
        }
    }
}

private struct RippleDeleteRangeCommand: EditorCommand {
    let before: Project
    let after: Project

    var name: String { "Ripple Delete Range" }

    func apply(to project: inout Project) {
        project = after
    }

    func revert(on project: inout Project) {
        project = before
    }
}

private struct TrimClipCommand: EditorCommand {
    let trackId: UUID
    let clipId: UUID

    let oldTimelineStartSeconds: Double
    let oldSourceInSeconds: Double
    let oldDurationSeconds: Double

    let newTimelineStartSeconds: Double
    let newSourceInSeconds: Double
    let newDurationSeconds: Double

    var name: String { "Trim Clip" }

    func apply(to project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipId }) else { return }
        project.timeline.tracks[trackIndex].clips[clipIndex].timelineStartSeconds = newTimelineStartSeconds
        project.timeline.tracks[trackIndex].clips[clipIndex].sourceInSeconds = newSourceInSeconds
        project.timeline.tracks[trackIndex].clips[clipIndex].durationSeconds = newDurationSeconds
    }

    func revert(on project: inout Project) {
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipId }) else { return }
        project.timeline.tracks[trackIndex].clips[clipIndex].timelineStartSeconds = oldTimelineStartSeconds
        project.timeline.tracks[trackIndex].clips[clipIndex].sourceInSeconds = oldSourceInSeconds
        project.timeline.tracks[trackIndex].clips[clipIndex].durationSeconds = oldDurationSeconds
    }
}

public enum TrackKind: String, Codable, Sendable {
    case video
    case audio
    case titles
    case adjustment
}

public struct Track: Codable, Sendable {
    public var id: UUID
    public var kind: TrackKind
    public var clips: [Clip]

    // Audio controls (MVP)
    public var isMuted: Bool
    public var isSolo: Bool

    public init(
        id: UUID = UUID(),
        kind: TrackKind,
        clips: [Clip] = [],
        isMuted: Bool = false,
        isSolo: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.clips = clips
        self.isMuted = isMuted
        self.isSolo = isSolo
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case clips
        case isMuted
        case isSolo
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(TrackKind.self, forKey: .kind)
        clips = try c.decode([Clip].self, forKey: .clips)
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSolo = try c.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
    }
}

public struct Clip: Codable, Sendable {
    public var id: UUID
    public var assetId: UUID

    // Timeline placement
    public var timelineStartSeconds: Double
    public var sourceInSeconds: Double
    public var durationSeconds: Double

    // Basic params (MVP)
    public var speed: Double

    // Audio params (MVP)
    public var volume: Double

    public init(
        id: UUID = UUID(),
        assetId: UUID,
        timelineStartSeconds: Double,
        sourceInSeconds: Double,
        durationSeconds: Double,
        speed: Double = 1.0,
        volume: Double = 1.0
    ) {
        self.id = id
        self.assetId = assetId
        self.timelineStartSeconds = timelineStartSeconds
        self.sourceInSeconds = sourceInSeconds
        self.durationSeconds = durationSeconds
        self.speed = speed
        self.volume = volume
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case assetId
        case timelineStartSeconds
        case sourceInSeconds
        case durationSeconds
        case speed
        case volume
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        assetId = try c.decode(UUID.self, forKey: .assetId)
        timelineStartSeconds = try c.decode(Double.self, forKey: .timelineStartSeconds)
        sourceInSeconds = try c.decode(Double.self, forKey: .sourceInSeconds)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
    }
}

// MARK: - Command / Undo

public protocol EditorCommand {
    var name: String { get }
    func apply(to project: inout Project)
    func revert(on project: inout Project)
}

public final class CommandStack {
    private var undoStack: [any EditorCommand] = []
    private var redoStack: [any EditorCommand] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var undoActionName: String? { undoStack.last?.name }
    public var redoActionName: String? { redoStack.last?.name }

    public func execute(_ command: any EditorCommand, on project: inout Project) {
        command.apply(to: &project)
        undoStack.append(command)
        redoStack.removeAll()
    }

    public func undo(on project: inout Project) {
        guard let command = undoStack.popLast() else { return }
        command.revert(on: &project)
        redoStack.append(command)
    }

    public func redo(on project: inout Project) {
        guard let command = redoStack.popLast() else { return }
        command.apply(to: &project)
        undoStack.append(command)
    }
}
