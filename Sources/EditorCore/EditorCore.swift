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
    public var importedAt: Date

    public init(id: UUID = UUID(), originalPath: String, importedAt: Date = Date()) {
        self.id = id
        self.originalPath = originalPath
        self.importedAt = importedAt
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
        let (trackId, oldStart) = try locateClip(clipId: clipId)
        let newStart = max(0, toStartSeconds)
        let command = MoveClipCommand(trackId: trackId, clipId: clipId, oldStartSeconds: oldStart, newStartSeconds: newStart)
        execute(command)
    }

    public func moveClips(_ moves: [(clipId: UUID, startSeconds: Double)]) throws {
        guard !moves.isEmpty else { return }

        var items: [MoveClipsCommand.Item] = []
        items.reserveCapacity(moves.count)

        for (clipId, startSeconds) in moves {
            let (trackId, oldStart) = try locateClip(clipId: clipId)
            let newStart = max(0, startSeconds)
            items.append(.init(trackId: trackId, clipId: clipId, oldStartSeconds: oldStart, newStartSeconds: newStart))
        }

        execute(MoveClipsCommand(items: items))
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
        let t = timeSeconds

        // Must split strictly inside clip bounds.
        guard t > start + 1e-9, t < end - 1e-9 else {
            throw ProjectEditError.invalidSplitTime(clipId: clipId, timeSeconds: timeSeconds)
        }

        let leftDisplay = t - start
        let rightDisplay = end - t
        if leftDisplay < ProjectEditorConstants.minClipDurationSeconds || rightDisplay < ProjectEditorConstants.minClipDurationSeconds {
            throw ProjectEditError.splitTooSmall(clipId: clipId, timeSeconds: timeSeconds)
        }

        let command = SplitClipCommand(
            trackId: located.trackId,
            clipIndex: located.clipIndex,
            original: clip,
            splitTimeSeconds: t
        )
        execute(command)
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
        let rightDisplay = end - t
        if leftDisplay < ProjectEditorConstants.minClipDurationSeconds || rightDisplay < ProjectEditorConstants.minClipDurationSeconds { return }

        let speed = clip.speed

        var left = clip
        left.durationSeconds = leftDisplay

        var right = clip
        right.id = rightClipId
        right.timelineStartSeconds = t
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

    public init(id: UUID = UUID(), kind: TrackKind, clips: [Clip] = []) {
        self.id = id
        self.kind = kind
        self.clips = clips
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

    public init(
        id: UUID = UUID(),
        assetId: UUID,
        timelineStartSeconds: Double,
        sourceInSeconds: Double,
        durationSeconds: Double,
        speed: Double = 1.0
    ) {
        self.id = id
        self.assetId = assetId
        self.timelineStartSeconds = timelineStartSeconds
        self.sourceInSeconds = sourceInSeconds
        self.durationSeconds = durationSeconds
        self.speed = speed
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
