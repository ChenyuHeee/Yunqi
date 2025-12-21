import Combine
import CoreGraphics
import EditorCore
import Foundation
import RenderEngine

/// SwiftUI 友好的封装：把 `EditorSession` 映射成 `ObservableObject`。
///
/// - `project` 会随着 `EditorSession.projectChanges()` 自动更新
/// - UI 可通过 `await` 调用编辑/播放方法
@MainActor
public final class EditorSessionStore: ObservableObject {
    @Published public private(set) var project: Project
    @Published public private(set) var previewImage: CGImage?
    @Published public private(set) var previewTimeSeconds: Double = 0

    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false
    @Published public private(set) var undoActionName: String? = nil
    @Published public private(set) var redoActionName: String? = nil

    private let session: EditorSession
    private var changesTask: Task<Void, Never>?

    public init(session: EditorSession) {
        self.session = session
        self.project = Project(meta: ProjectMeta(name: "Loading"))
        self.previewImage = nil

        changesTask = Task { [weak self] in
            guard let self else { return }
            let stream = await session.projectChanges()
            for await project in stream {
                self.project = project
                self.canUndo = await session.canUndo()
                self.canRedo = await session.canRedo()
                self.undoActionName = await session.undoActionName()
                self.redoActionName = await session.redoActionName()
            }
        }

        Task {
            self.project = await session.snapshot()
            self.canUndo = await session.canUndo()
            self.canRedo = await session.canRedo()
            self.undoActionName = await session.undoActionName()
            self.redoActionName = await session.redoActionName()
        }
    }

    deinit {
        changesTask?.cancel()
    }

    // MARK: - Editing

    @discardableResult
    public func importAsset(path: String, id: UUID = UUID()) async -> UUID {
        await session.importAsset(path: path, id: id)
    }

    public func addTrack(kind: TrackKind) async {
        await session.addTrack(kind: kind)
    }

    public func addClip(
        trackIndex: Int,
        assetId: UUID,
        timelineStartSeconds: Double,
        sourceInSeconds: Double,
        durationSeconds: Double,
        speed: Double = 1.0
    ) async throws {
        try await session.addClip(
            trackIndex: trackIndex,
            assetId: assetId,
            timelineStartSeconds: timelineStartSeconds,
            sourceInSeconds: sourceInSeconds,
            durationSeconds: durationSeconds,
            speed: speed
        )
    }

    public func moveClip(clipId: UUID, toStartSeconds: Double) async throws {
        try await session.moveClip(clipId: clipId, toStartSeconds: toStartSeconds)
    }
    
    public func moveClips(_ moves: [(clipId: UUID, startSeconds: Double)]) async throws {
        try await session.moveClips(moves)
    }

    public func trimClip(
        clipId: UUID,
        newTimelineStartSeconds: Double? = nil,
        newSourceInSeconds: Double? = nil,
        newDurationSeconds: Double? = nil
    ) async throws {
        try await session.trimClip(
            clipId: clipId,
            newTimelineStartSeconds: newTimelineStartSeconds,
            newSourceInSeconds: newSourceInSeconds,
            newDurationSeconds: newDurationSeconds
        )
    }

    public func deleteClip(clipId: UUID) async throws {
        try await session.deleteClip(clipId: clipId)
    }
    
    public func deleteClips(clipIds: [UUID]) async throws {
        try await session.deleteClips(clipIds: clipIds)
    }

    public func rippleDeleteClips(clipIds: [UUID]) async throws {
        try await session.rippleDeleteClips(clipIds: clipIds)
    }

    public func rippleDeleteRange(inSeconds: Double, outSeconds: Double) async throws {
        await session.rippleDeleteRange(inSeconds: inSeconds, outSeconds: outSeconds)
    }

    public func splitClip(clipId: UUID, at timeSeconds: Double) async throws {
        try await session.splitClip(clipId: clipId, at: timeSeconds)
    }

    public func undo() async {
        await session.undo()
    }

    public func redo() async {
        await session.redo()
    }

    // MARK: - Playback

    public func configurePlayback(
        engine: any RenderEngine,
        onFrame: PlaybackController.FrameHandler? = nil
    ) async {
        let userOnFrame = onFrame
        await session.configurePlayback(
            engine: engine,
            onFrame: { [weak self] frame in
                // Update SwiftUI preview on main actor.
                Task { @MainActor in
                    self?.updatePreview(frame)
                }
                userOnFrame?(frame)
            }
        )
    }

    public func preparePlayback() async throws {
        try await session.preparePlayback()
    }

    public func play(fps: Double? = nil) async {
        await session.play(fps: fps)
    }

    public func pause() async {
        await session.pause()
    }

    public func stop() async {
        await session.stop()
    }

    public func seek(to timeSeconds: Double) async {
        await session.seek(to: timeSeconds)
    }

    public func playbackState() async -> PlaybackState {
        await session.playbackState()
    }

    public func playbackTimeSeconds() async -> Double {
        await session.playbackTimeSeconds()
    }

    // MARK: - Preview

    private func updatePreview(_ frame: RenderedFrame) {
        previewTimeSeconds = frame.timeSeconds
        previewImage = Self.makeCGImage(from: frame)
    }

    private static func makeCGImage(from frame: RenderedFrame) -> CGImage? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let expected = frame.width * frame.height * 4
        guard frame.rgba.count == expected else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let bytesPerRow = frame.width * 4

        guard let provider = CGDataProvider(data: frame.rgba as CFData) else { return nil }

        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
