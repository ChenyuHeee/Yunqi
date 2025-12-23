import EditorCore
import Foundation
import RenderEngine

public enum PlaybackState: Sendable, Equatable {
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
