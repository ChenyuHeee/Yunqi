import Foundation
import RenderEngine

/// UI 友好的门面：把工程编辑（ProjectEditor）与回放调度（PlaybackController）组合在一起。
///
/// 设计目标：
/// - UI 只和 `EditorSession` 交互（获取 snapshot / 触发编辑命令 / 控制播放）
/// - 内部细节（命令栈、回放 Task、渲染引擎）对 UI 隐藏
public actor EditorSession {
    private let editor: ProjectEditor
    private var playback: PlaybackController?

    private var changeContinuations: [UUID: AsyncStream<Project>.Continuation] = [:]

    public init(project: Project) {
        self.editor = ProjectEditor(project: project)
    }

    // MARK: - Snapshot

    public func snapshot() -> Project {
        editor.project
    }

    /// 订阅工程变更流（会先推送一次当前 snapshot）。
    ///
    /// 用法（SwiftUI / ViewModel 里）：
    /// `for await project in await session.projectChanges() { ... }`
    public func projectChanges() -> AsyncStream<Project> {
        AsyncStream { continuation in
            let id = UUID()
            changeContinuations[id] = continuation
            continuation.yield(editor.project)

            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        changeContinuations[id] = nil
    }

    private func notifyProjectChanged() {
        let snap = editor.project
        for continuation in changeContinuations.values {
            continuation.yield(snap)
        }
    }

    // MARK: - Editing

    @discardableResult
    public func importAsset(path: String, id: UUID = UUID()) -> UUID {
        let assetId = editor.importAsset(path: path, id: id)
        notifyProjectChanged()
        return assetId
    }

    public func renameAsset(assetId: UUID, displayName: String) throws {
        try editor.renameAsset(assetId: assetId, displayName: displayName)
        notifyProjectChanged()
    }

    public func addTrack(kind: TrackKind) {
        editor.addTrack(kind: kind)
        notifyProjectChanged()
    }

    public func addClip(
        trackIndex: Int,
        assetId: UUID,
        timelineStartSeconds: Double,
        sourceInSeconds: Double,
        durationSeconds: Double,
        speed: Double = 1.0
    ) throws {
        try editor.addClip(
            trackIndex: trackIndex,
            assetId: assetId,
            timelineStartSeconds: timelineStartSeconds,
            sourceInSeconds: sourceInSeconds,
            durationSeconds: durationSeconds,
            speed: speed
        )
        notifyProjectChanged()
    }

    public func moveClip(clipId: UUID, toStartSeconds: Double) throws {
        try editor.moveClip(clipId: clipId, toStartSeconds: toStartSeconds)
        notifyProjectChanged()
    }

    public func moveClips(_ moves: [(clipId: UUID, startSeconds: Double)]) throws {
        try editor.moveClips(moves)
        notifyProjectChanged()
    }

    public func trimClip(
        clipId: UUID,
        newTimelineStartSeconds: Double? = nil,
        newSourceInSeconds: Double? = nil,
        newDurationSeconds: Double? = nil
    ) throws {
        try editor.trimClip(
            clipId: clipId,
            newTimelineStartSeconds: newTimelineStartSeconds,
            newSourceInSeconds: newSourceInSeconds,
            newDurationSeconds: newDurationSeconds
        )
        notifyProjectChanged()
    }

    public func deleteClip(clipId: UUID) throws {
        try editor.deleteClip(clipId: clipId)
        notifyProjectChanged()
    }

    public func deleteClips(clipIds: [UUID]) throws {
        try editor.deleteClips(clipIds: clipIds)
        notifyProjectChanged()
    }

    public func rippleDeleteClips(clipIds: [UUID]) throws {
        try editor.rippleDeleteClips(clipIds: clipIds)
        notifyProjectChanged()
    }

    public func rippleDeleteRange(inSeconds: Double, outSeconds: Double) {
        editor.rippleDeleteRange(inSeconds: inSeconds, outSeconds: outSeconds)
        notifyProjectChanged()
    }

    public func splitClip(clipId: UUID, at timeSeconds: Double) throws {
        try editor.splitClip(clipId: clipId, at: timeSeconds)
        notifyProjectChanged()
    }

    public func splitClips(clipIds: [UUID], at timeSeconds: Double) {
        editor.splitClips(clipIds: clipIds, at: timeSeconds)
        notifyProjectChanged()
    }

    public func setClipVolume(clipId: UUID, volume: Double) throws {
        try editor.setClipVolume(clipId: clipId, volume: volume)
        notifyProjectChanged()
    }

    public func toggleTrackMute(trackId: UUID) throws {
        try editor.toggleTrackMute(trackId: trackId)
        notifyProjectChanged()
    }

    public func toggleTrackSolo(trackId: UUID) throws {
        try editor.toggleTrackSolo(trackId: trackId)
        notifyProjectChanged()
    }

    public func undo() {
        editor.undo()
        notifyProjectChanged()
    }

    public func redo() {
        editor.redo()
        notifyProjectChanged()
    }

    public func canUndo() -> Bool {
        editor.canUndo
    }

    public func canRedo() -> Bool {
        editor.canRedo
    }

    public func undoActionName() -> String? {
        editor.undoActionName
    }

    public func redoActionName() -> String? {
        editor.redoActionName
    }

    // MARK: - Playback

    /// 配置回放控制器（可在 UI 初始化播放器时调用）。
    public func configurePlayback(
        engine: any RenderEngine,
        onFrame: PlaybackController.FrameHandler? = nil
    ) {
        self.playback = PlaybackController(
            projectSnapshot: { await self.snapshot() },
            engine: engine,
            onFrame: onFrame
        )
    }

    public func preparePlayback() async throws {
        guard let playback else { return }
        try await playback.prepare()
    }

    public func play(fps: Double? = nil) async {
        guard let playback else { return }
        await playback.play(fps: fps)
    }

    public func pause() async {
        guard let playback else { return }
        await playback.pause()
    }

    public func stop() async {
        guard let playback else { return }
        await playback.stop()
    }

    public func seek(to timeSeconds: Double) async {
        guard let playback else { return }
        await playback.seek(to: timeSeconds)
    }

    public func playbackState() async -> PlaybackState {
        guard let playback else { return .stopped }
        return await playback.getState()
    }

    public func playbackTimeSeconds() async -> Double {
        guard let playback else { return 0 }
        return await playback.getCurrentTimeSeconds()
    }
}
