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
}

private enum ProjectEditorConstants {
    static let minClipDurationSeconds: Double = 0.05
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
