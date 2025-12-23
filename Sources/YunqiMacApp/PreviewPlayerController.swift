@preconcurrency import AVFoundation
import AppKit
import CoreImage
import ImageIO
import QuartzCore
import EditorCore
import RenderEngine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PreviewPlayerController {
    let player: AVPlayer = AVPlayer()

    var onDebug: ((String) -> Void)?

    private var requestedRate: Float = 0

    var currentRequestedRate: Float { requestedRate }

    private var lastProjectFingerprint: Int?
    private var buildTask: Task<Void, Never>?
    private var timeObserverToken: Any?
    private var timeUpdateCallback: (@Sendable (Double) -> Void)?

    private var reverseShuttleTimer: Timer?
    private var reverseShuttleSeeking: Bool = false
    private var wasMutedBeforeReverse: Bool = false
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemErrorObservation: NSKeyValueObservation?

    private var videoOutput: AVPlayerItemVideoOutput?
    private var videoFrameTimer: Timer?
    private let ciContext = CIContext(options: nil)
    private var didDumpVideoOutputFrame: Bool = false
    private weak var videoOutputItem: AVPlayerItem?

    private(set) var currentVideoPreferredTransform: CGAffineTransform = .identity

    private static let overlayColorSpace: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }()

    private static let isPreviewFrameDumpEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["YUNQI_DUMP_PREVIEW_FRAMES"] == "1"
    }()

    private struct SendableOpaquePointer: @unchecked Sendable {
        let raw: UnsafeMutableRawPointer
    }

    enum ExportError: Error, CustomStringConvertible {
        case cannotCreateExportSession
        case exportFailed(status: AVAssetExportSession.Status, underlying: Error?)

        var description: String {
            switch self {
            case .cannotCreateExportSession:
                return "Cannot create AVAssetExportSession"
            case let .exportFailed(status, underlying):
                return "Export failed status=\(status.rawValue) error=\(underlying?.localizedDescription ?? "nil")"
            }
        }
    }

    func updateProject(_ project: Project, preserveTime: Bool = true) {
        let fingerprint = Self.fingerprint(project)
        if fingerprint == lastProjectFingerprint {
            return
        }
        lastProjectFingerprint = fingerprint

        // 用显式 rate 表达“用户是否请求播放”，避免 item 为空/等待时 rate/timeControlStatus 不稳定。
        let rateAfterRebuild = requestedRate
        let currentTime = preserveTime ? player.currentTime() : .zero

        buildTask?.cancel()
        buildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.onDebug?("Building preview item…")
            // For long-term correctness, keep preview consistent with export by always
            // going through the composition + videoComposition path.
            // (The direct-asset fast path can hide compositor/conform issues and cause
            // preview/export divergence.)
            let result = await Self.buildPlayerItem(for: project, allowDirectAsset: false)
            if Task.isCancelled { return }

            // Detach any existing video output from the previous item *before* swapping.
            self.detachVideoOutputFromCurrentItemIfNeeded()
            self.player.replaceCurrentItem(with: result.item)
            self.onDebug?(result.debug)

            self.attachVideoOutput(to: result.item)

            // Observe item readiness/errors (diagnostics for blank preview).
            self.itemStatusObservation?.invalidate()
            self.itemErrorObservation?.invalidate()
            let item = result.item
            self.itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let statusText: String
                switch item.status {
                case .unknown: statusText = "unknown"
                case .readyToPlay: statusText = "ready"
                case .failed: statusText = "failed"
                @unknown default: statusText = "?"
                }
                let msg = "[Preview] item.status=\(statusText) tracks=\(item.tracks.count)"
                Task { @MainActor [weak self] in
                    self?.onDebug?(msg)
                }
                NSLog("%@", msg)
            }
            self.itemErrorObservation = item.observe(\.error, options: [.initial, .new]) { [weak self] item, _ in
                if let err = item.error {
                    let msg = "[Preview] item.error=\(err.localizedDescription)"
                    Task { @MainActor [weak self] in
                        self?.onDebug?(msg)
                    }
                    NSLog("%@", msg)
                }
            }

            if preserveTime {
                self.player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }

            if rateAfterRebuild != 0 {
                self.player.playImmediately(atRate: rateAfterRebuild)
            }
        }
    }

    func play() {
        setRate(1)
    }

    func pause() {
        setRate(0)
    }

    func stop() {
        setRate(0)
        player.seek(to: .zero) { _ in }
    }

    func setRate(_ rate: Float) {
        requestedRate = rate

        // AVPlayer doesn't support negative playback rates. Implement a simple reverse shuttle
        // by repeatedly seeking backwards; video frames still come from AVPlayerItemVideoOutput.
        if rate < 0 {
            startReverseShuttle(rate: rate)
            return
        }

        stopReverseShuttleIfNeeded()
        if rate == 0 {
            player.pause()
        } else {
            player.playImmediately(atRate: rate)
        }
    }

    private func startReverseShuttle(rate: Float) {
        // Clamp to a reasonable range; TimelineNSView currently caps at 8x.
        let r = max(-8, min(-0.1, rate))
        requestedRate = r

        // Ensure we are paused while shuttling.
        player.pause()

        if reverseShuttleTimer == nil {
            wasMutedBeforeReverse = player.isMuted
            player.isMuted = true
        }

        reverseShuttleTimer?.invalidate()
        reverseShuttleSeeking = false

        let tickHz: Double = 30.0
        reverseShuttleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / tickHz, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.reverseShuttleSeeking else { return }
                guard let item = self.player.currentItem else { return }

                let current = item.currentTime().seconds
                guard current.isFinite else { return }

                let dt = (1.0 / tickHz) * Double(abs(self.requestedRate))
                let targetSeconds = max(0.0, current - dt)
                let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)

                self.reverseShuttleSeeking = true
                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.reverseShuttleSeeking = false
                        self.timeUpdateCallback?(targetSeconds)

                        // Stop cleanly at the start.
                        if targetSeconds <= 0.000_001 {
                            self.setRate(0)
                        }
                    }
                }
            }
        }

        // Immediate UI update.
        timeUpdateCallback?(player.currentTime().seconds)
    }

    private func stopReverseShuttleIfNeeded() {
        reverseShuttleTimer?.invalidate()
        reverseShuttleTimer = nil
        reverseShuttleSeeking = false
        player.isMuted = wasMutedBeforeReverse
    }

    func seek(seconds: Double, completion: (@Sendable () -> Void)? = nil) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            completion?()
        }
    }

    // MARK: - Export

    func export(
        project: Project,
        to outputURL: URL,
        presetName: String = AVAssetExportPresetHighestQuality,
        fileType: AVFileType = .mp4,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let result = await Self.buildPlayerItem(for: project, allowDirectAsset: false)
        let asset = result.item.asset

        // Overwrite target if exists.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw ExportError.cannotCreateExportSession
        }
        session.outputURL = outputURL
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let vc = result.item.videoComposition {
            session.videoComposition = vc
        }

        // Avoid capturing non-Sendable AVAssetExportSession in the export completion closure.
        // Use an opaque pointer which is Sendable, and only re-hydrate on MainActor.
        let sessionPtr = SendableOpaquePointer(raw: Unmanaged.passUnretained(session).toOpaque())

        let progressTask = Task { @MainActor in
            while session.status == .exporting {
                onProgress?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }
        defer {
            progressTask.cancel()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    Task { @MainActor in
                        let session = Unmanaged<AVAssetExportSession>.fromOpaque(sessionPtr.raw).takeUnretainedValue()
                        let status = session.status
                        let progress = Double(session.progress)
                        let error = session.error

                        onProgress?(progress)
                        switch status {
                        case .completed:
                            cont.resume()
                        case .cancelled:
                            cont.resume(throwing: CancellationError())
                        case .failed, .unknown, .waiting, .exporting:
                            cont.resume(throwing: ExportError.exportFailed(status: status, underlying: error))
                        @unknown default:
                            cont.resume(throwing: ExportError.exportFailed(status: status, underlying: error))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                let session = Unmanaged<AVAssetExportSession>.fromOpaque(sessionPtr.raw).takeUnretainedValue()
                session.cancelExport()
            }
        }

        onProgress?(1.0)
    }

    func startTimeUpdates(_ onUpdate: @escaping @Sendable (Double) -> Void) {
        stopTimeUpdates()
        timeUpdateCallback = onUpdate
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            onUpdate(time.seconds)
        }
    }


    func stopTimeUpdates() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        timeUpdateCallback = nil
    }

    // MARK: - Video frame tap (overlay rendering)

    func startVideoFrameUpdates(_ onFrame: @escaping @Sendable (CGImage?) -> Void) {
        stopVideoFrameUpdates()

        // Poll decoded output at ~30fps on main runloop.
        videoFrameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let item = self.player.currentItem, let output = self.videoOutput else {
                    onFrame(nil)
                    return
                }

                // Prefer hostTime mapping; falls back to currentTime.
                let hostTime = CACurrentMediaTime()
                var itemTime = output.itemTime(forHostTime: hostTime)
                if !itemTime.isValid || !itemTime.isNumeric {
                    itemTime = item.currentTime()
                }
                var displayTime = CMTime.zero
                guard output.hasNewPixelBuffer(forItemTime: itemTime),
                      let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime)
                else {
                    return
                }

                let ci = CIImage(cvPixelBuffer: pb)

                // Be explicit about output format/colorspace; some systems otherwise yield a white CGImage.
                let cg = self.ciContext.createCGImage(
                    ci,
                    from: ci.extent,
                    format: .BGRA8,
                    colorSpace: Self.overlayColorSpace
                ) ?? self.ciContext.createCGImage(ci, from: ci.extent)

                if let cg {
                    if Self.isPreviewFrameDumpEnabled, !self.didDumpVideoOutputFrame {
                        self.didDumpVideoOutputFrame = true
                        self.dumpVideoOutputFramePNG(cg)
                    }
                    onFrame(cg)
                }
            }
        }
    }

    func startVideoPixelBufferUpdates(_ onPixelBuffer: @escaping @MainActor @Sendable (CVPixelBuffer?) -> Void) {
        stopVideoFrameUpdates()

        // Poll decoded output at ~30fps on main runloop.
        videoFrameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let item = self.player.currentItem, let output = self.videoOutput else {
                    onPixelBuffer(nil)
                    return
                }

                let hostTime = CACurrentMediaTime()
                var itemTime = output.itemTime(forHostTime: hostTime)
                if !itemTime.isValid || !itemTime.isNumeric {
                    itemTime = item.currentTime()
                }

                var displayTime = CMTime.zero
                guard output.hasNewPixelBuffer(forItemTime: itemTime),
                      let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime)
                else {
                    return
                }

                if Self.isPreviewFrameDumpEnabled, !self.didDumpVideoOutputFrame {
                    self.didDumpVideoOutputFrame = true
                    self.dumpVideoOutputPixelBufferPNG(pb)
                }

                onPixelBuffer(pb)
            }
        }
    }

    private func dumpVideoOutputPixelBufferPNG(_ pb: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: pb)
        let cg = self.ciContext.createCGImage(
            ci,
            from: ci.extent,
            format: .BGRA8,
            colorSpace: Self.overlayColorSpace
        ) ?? self.ciContext.createCGImage(ci, from: ci.extent)

        guard let cg else {
            NSLog("[Preview] Failed to create CGImage from videoOutput pixelBuffer")
            return
        }

        let url = URL(fileURLWithPath: "/tmp/yunqi-videooutput-pb-1.png")
        DispatchQueue.global(qos: .utility).async {
            guard let data = Self.pngData(from: cg) else {
                NSLog("[Preview] Failed to encode videoOutput pixelBuffer as PNG")
                return
            }
            do {
                try data.write(to: url, options: [.atomic])
                NSLog("[Preview] Saved videoOutput pixelBuffer PNG: %@", url.path)
            } catch {
                NSLog("[Preview] Failed to write videoOutput pixelBuffer PNG: %@ error=%@", url.path, String(describing: error))
            }
        }
    }

    func stopVideoFrameUpdates() {
        videoFrameTimer?.invalidate()
        videoFrameTimer = nil
    }

    private func attachVideoOutput(to item: AVPlayerItem) {
        // Detach any previous output defensively.
        detachVideoOutputFromCurrentItemIfNeeded()

        // Use default output settings to avoid Swift 6 Sendable warnings from [String: Any].
        // The Metal preview path handles common YUV formats efficiently via CVMetalTextureCache.
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(out)
        videoOutput = out
        videoOutputItem = item
        didDumpVideoOutputFrame = false

        // Encourage output to start producing data.
        out.requestNotificationOfMediaDataChange(withAdvanceInterval: 1.0 / 30.0)

        // Track transform for correct orientation in Metal preview (and other raw-frame consumers).
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .video)
                if let t = tracks.first {
                    self.currentVideoPreferredTransform = (try? await t.load(.preferredTransform)) ?? .identity
                } else {
                    self.currentVideoPreferredTransform = .identity
                }
            } catch {
                self.currentVideoPreferredTransform = .identity
            }
        }
    }

    private func dumpVideoOutputFramePNG(_ frame: CGImage) {
        let url = URL(fileURLWithPath: "/tmp/yunqi-videooutput-frame-1.png")
        DispatchQueue.global(qos: .utility).async {
            guard let data = Self.pngData(from: frame) else {
                NSLog("[Preview] Failed to encode videoOutput frame as PNG")
                return
            }
            do {
                try data.write(to: url, options: [.atomic])
                NSLog("[Preview] Saved videoOutput PNG: %@", url.path)
            } catch {
                NSLog("[Preview] Failed to write videoOutput PNG: %@ error=%@", url.path, String(describing: error))
            }
        }
    }

    nonisolated private static func pngData(from image: CGImage) -> Data? {
        let mutable = CFDataCreateMutable(nil, 0)
        guard let mutable else { return nil }
        guard let dest = CGImageDestinationCreateWithData(mutable, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutable as Data
    }

    private func detachVideoOutputFromCurrentItemIfNeeded() {
        if let old = videoOutput, let boundItem = videoOutputItem {
            boundItem.remove(old)
        }
        videoOutput = nil
        videoOutputItem = nil
    }

    // 注意：清理由调用方在主线程显式 stopTimeUpdates()。

    // MARK: - Composition

    private struct PlayerItemBuildResult {
        let item: AVPlayerItem
        let debug: String
    }

    private struct Segment {
        let clipId: UUID
        let asset: AVAsset
        let assetVideoTrack: AVAssetTrack
        let trackIndex: Int
        let start: Double
        let end: Double
        let sourceIn: Double
        let sourceDuration: Double
        let displayDuration: Double
        let zIndex: Int

        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
    }

    /// Build an export-ready asset for a project.
    ///
    /// This intentionally reuses the same composition logic as preview, but forces the
    /// composition path (no direct-asset fast path) so trims/timeRanges are respected.
    struct ExportBuildResult {
        let asset: AVAsset
        let videoComposition: AVVideoComposition?
        let audioMix: AVAudioMix?
    }

    static func buildExportPipeline(for project: Project) async -> ExportBuildResult {
        let result = await buildPlayerItem(for: project, allowDirectAsset: false)
        let item = result.item
        return ExportBuildResult(asset: item.asset, videoComposition: item.videoComposition, audioMix: item.audioMix)
    }

    static func buildExportAsset(for project: Project) async -> AVAsset {
        let built = await buildExportPipeline(for: project)
        return built.asset
    }

    private static func buildPlayerItem(for project: Project, allowDirectAsset: Bool) async -> PlayerItemBuildResult {
        let timeScale: CMTimeScale = 60_000
        let composition = AVMutableComposition()

        let collected = await collectVideoSegments(project)
        let videoSegments = collected.segments
        if !collected.warnings.isEmpty {
            // keep going; warnings will be surfaced via debug string
        }

        guard !videoSegments.isEmpty else {
            let videoClipCount = project.timeline.tracks.filter { $0.kind == .video }.flatMap { $0.clips }.count

            // Audio-only fallback: build an audio composition so playback still works.
            let audioCollected = await collectAudioSegments(project)
            let audioSegments = audioCollected.segments

            if audioSegments.isEmpty {
                let debug = ([
                    "Preview build: no playable video segments",
                    "videoClips=\(videoClipCount)",
                    "audioClips=\(project.timeline.tracks.filter { $0.kind == .audio }.flatMap { $0.clips }.count)",
                    "mediaAssets=\(project.mediaAssets.count)",
                    (collected.warnings + audioCollected.warnings).isEmpty ? nil : ("warnings:\n" + (collected.warnings + audioCollected.warnings).joined(separator: "\n"))
                ].compactMap { $0 }).joined(separator: "\n")
                return PlayerItemBuildResult(item: AVPlayerItem(asset: composition), debug: debug)
            }

            // Partition audio segments into non-overlapping lanes (composition tracks).
            var lanes: [[AudioSegment]] = []
            for seg in audioSegments.sorted(by: { $0.start < $1.start }) {
                var placed = false
                for i in lanes.indices {
                    if let last = lanes[i].last, last.end <= seg.start + 1e-9 {
                        lanes[i].append(seg)
                        placed = true
                        break
                    }
                }
                if !placed {
                    lanes.append([seg])
                }
            }

            let anySolo = project.timeline.tracks.contains { $0.isSolo }
            let clipVolumeById: [UUID: Double] = Dictionary(uniqueKeysWithValues: project.timeline.tracks.flatMap { $0.clips }.map { ($0.id, $0.volume) })
            let trackAudibleFactorById: [UUID: Double] = Dictionary(uniqueKeysWithValues: project.timeline.tracks.map { track in
                let audible = (!track.isMuted) && (!anySolo || track.isSolo)
                return (track.id, audible ? 1.0 : 0.0)
            })

            var inputParams: [AVMutableAudioMixInputParameters] = []
            inputParams.reserveCapacity(lanes.count)

            for lane in lanes {
                guard let audioCompTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    continue
                }

                let params = AVMutableAudioMixInputParameters(track: audioCompTrack)

                for seg in lane {
                    let insertionTime = CMTime(seconds: seg.start, preferredTimescale: 600)
                    let sourceRange = CMTimeRange(
                        start: CMTime(seconds: seg.sourceIn, preferredTimescale: 600),
                        duration: CMTime(seconds: seg.sourceDuration, preferredTimescale: 600)
                    )

                    do {
                        try audioCompTrack.insertTimeRange(sourceRange, of: seg.assetAudioTrack, at: insertionTime)

                        let insertedRange = CMTimeRange(start: insertionTime, duration: sourceRange.duration)
                        let targetDuration = CMTime(seconds: seg.displayDuration, preferredTimescale: 600)
                        if targetDuration != sourceRange.duration {
                            audioCompTrack.scaleTimeRange(insertedRange, toDuration: targetDuration)
                        }

                        let clipVol = max(0, clipVolumeById[seg.clipId] ?? 1.0)
                        let trackFactor = trackAudibleFactorById[seg.timelineTrackId] ?? 1.0
                        let effective = Float(max(0, min(2.0, clipVol * trackFactor)))
                        let displayRange = CMTimeRange(start: insertionTime, duration: targetDuration)
                        params.setVolumeRamp(fromStartVolume: effective, toEndVolume: effective, timeRange: displayRange)
                    } catch {
                        continue
                    }
                }

                inputParams.append(params)
            }

            let item = AVPlayerItem(asset: composition)
            if !inputParams.isEmpty {
                let audioMix = AVMutableAudioMix()
                audioMix.inputParameters = inputParams
                item.audioMix = audioMix
            }

            let totalDuration = audioSegments.map { $0.end }.max() ?? 0
            let debug = ([
                "Preview build: audio-only composition",
                "videoClips=\(videoClipCount)",
                "audioSegments=\(audioSegments.count) lanes=\(lanes.count)",
                String(format: "duration=%.2fs fps=%.0f", totalDuration, project.meta.fps),
                "compositionAudioTracks=\(composition.tracks(withMediaType: .audio).count)",
                (collected.warnings + audioCollected.warnings).isEmpty ? nil : ("warnings:\n" + (collected.warnings + audioCollected.warnings).joined(separator: "\n"))
            ].compactMap { $0 }).joined(separator: "\n")

            return PlayerItemBuildResult(item: item, debug: debug)
        }

        let hasAudioAdjustments = project.timeline.tracks.contains { $0.isMuted || $0.isSolo }
            || project.timeline.tracks.flatMap { $0.clips }.contains { abs($0.volume - 1.0) > 1e-9 }

        let disableDirectAssetFastPath = ProcessInfo.processInfo.environment["YUNQI_DISABLE_DIRECT_ASSET"] == "1"

        // Fast path (debug & correctness baseline):
        // If timeline is a single clip starting at 0 with no speed/trim offsets, play the original asset directly.
        // NOTE: for export, we disable this so trims/timeRange are always reflected by the composition.
        if allowDirectAsset, !disableDirectAssetFastPath, !hasAudioAdjustments, videoSegments.count == 1, let seg = videoSegments.first {
            let projectCanvas = CGSize(width: project.meta.renderSize.width, height: project.meta.renderSize.height)
            let segDisplay = seg.naturalSize.applying(seg.preferredTransform).absoluteSize
            let approxSameCanvas = abs(projectCanvas.width - segDisplay.width) <= 0.5 && abs(projectCanvas.height - segDisplay.height) <= 0.5
            let conformIsDefault = project.meta.spatialConformDefault == .fit
            let isSimple = abs(seg.start - 0) < 1e-9
                && abs(seg.sourceIn - 0) < 1e-9
                && abs(seg.displayDuration - seg.sourceDuration) < 1e-6
                && abs(seg.displayDuration - (seg.end - seg.start)) < 1e-9

            // Only allow this if it doesn't bypass project-canvas conform.
            if isSimple, approxSameCanvas, conformIsDefault {
                let item = AVPlayerItem(asset: seg.asset)
                let debug = ([
                    "Preview build: direct",
                    "asset=AVURLAsset",
                    String(format: "duration=%.2fs fps=%.0f", seg.displayDuration, project.meta.fps)
                ]).joined(separator: "\n")
                return PlayerItemBuildResult(item: item, debug: debug)
            }
        }

        // Final Cut Pro-like viewer: render into the project canvas.
        let renderSize = CGSize(width: project.meta.renderSize.width, height: project.meta.renderSize.height)

        // Partition segments into non-overlapping composition tracks.
        var lanes: [[Segment]] = []
        for seg in videoSegments.sorted(by: { $0.start < $1.start }) {
            var placed = false
            for i in lanes.indices {
                if let last = lanes[i].last, last.end <= seg.start + 1e-9 {
                    lanes[i].append(seg)
                    placed = true
                    break
                }
            }
            if !placed {
                lanes.append([seg])
            }
        }

        var compTracks: [AVMutableCompositionTrack] = []
        for _ in lanes {
            if let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                compTracks.append(t)
            }
        }

        // If there is only one lane, we can also build a single audio track by inserting
        // each clip's audio at its timeline time. This restores basic audio playback.
        let audioCompTrack: AVMutableCompositionTrack? =
            (lanes.count == 1) ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        let anySolo = project.timeline.tracks.contains { $0.isSolo }
        let clipVolumeById: [UUID: Double] = Dictionary(uniqueKeysWithValues: project.timeline.tracks.flatMap { $0.clips }.map { ($0.id, $0.volume) })

        let clipConformById: [UUID: SpatialConform] = Dictionary(uniqueKeysWithValues: project.timeline.tracks.flatMap { $0.clips }.map {
            ($0.id, $0.spatialConformOverride ?? project.meta.spatialConformDefault)
        })

        let trackAudibleFactorById: [UUID: Double] = Dictionary(uniqueKeysWithValues: project.timeline.tracks.map { track in
            let audible = (!track.isMuted) && (!anySolo || track.isSolo)
            return (track.id, audible ? 1.0 : 0.0)
        })

        var audioParams: AVMutableAudioMixInputParameters? = nil
        if let audioCompTrack {
            audioParams = AVMutableAudioMixInputParameters(track: audioCompTrack)
        }

        // Insert segments.
        for (laneIndex, lane) in lanes.enumerated() {
            let compTrack = compTracks[laneIndex]
            for seg in lane {
                let insertionTime = CMTime(seconds: seg.start, preferredTimescale: timeScale)
                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: seg.sourceIn, preferredTimescale: timeScale),
                    duration: CMTime(seconds: seg.sourceDuration, preferredTimescale: timeScale)
                )

                do {
                    try compTrack.insertTimeRange(sourceRange, of: seg.assetVideoTrack, at: insertionTime)

                    // Speed: scale inserted time range to displayDuration.
                    let insertedRange = CMTimeRange(start: insertionTime, duration: sourceRange.duration)
                    let targetDuration = CMTime(seconds: seg.displayDuration, preferredTimescale: timeScale)
                    if targetDuration != sourceRange.duration {
                        compTrack.scaleTimeRange(insertedRange, toDuration: targetDuration)
                    }

                    // Audio (best-effort): only for lanes==1 to avoid overlap conflicts.
                    if laneIndex == 0, let audioCompTrack {
                        if let audioTrack = try? await seg.asset.loadTracks(withMediaType: .audio).first {
                            try? audioCompTrack.insertTimeRange(sourceRange, of: audioTrack, at: insertionTime)
                            if targetDuration != sourceRange.duration {
                                audioCompTrack.scaleTimeRange(insertedRange, toDuration: targetDuration)
                            }

                            // Apply per-clip volume + track mute/solo via audio mix.
                            let clipVol = max(0, clipVolumeById[seg.clipId] ?? 1.0)
                            let trackId = project.timeline.tracks.indices.contains(seg.trackIndex) ? project.timeline.tracks[seg.trackIndex].id : nil
                            let trackFactor = (trackId.flatMap { trackAudibleFactorById[$0] }) ?? 1.0
                            let effective = Float(max(0, min(2.0, clipVol * trackFactor)))
                            let displayRange = CMTimeRange(start: insertionTime, duration: targetDuration)
                            audioParams?.setVolumeRamp(fromStartVolume: effective, toEndVolume: effective, timeRange: displayRange)
                        }
                    }
                } catch {
                    // Skip bad segments.
                    continue
                }
            }
        }

        // Build a video composition that selects the topmost visible segment per time slice.
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(seconds: 1.0 / max(1, project.meta.fps), preferredTimescale: timeScale)

        // Default to our Metal-based compositor. This keeps preview/export semantics identical
        // while moving composition work onto the GPU.
        //
        // Set YUNQI_VIDEO_COMPOSITOR=avfoundation to force AVFoundation's default compositor.
        let compositorEnv = ProcessInfo.processInfo.environment["YUNQI_VIDEO_COMPOSITOR"]?.lowercased()
        if compositorEnv != "avfoundation" && compositorEnv != "system" && compositorEnv != "default" {
            videoComposition.customVideoCompositorClass = MetalVideoCompositor.self
        }

        // IMPORTANT: build instruction boundaries in CMTime and derive timeRanges from those CMTime values.
        // Converting (Double start/end) -> CMTime separately can introduce tiny rounding gaps that show as flashes at cuts.
        let boundarySeconds = collectBoundaries(videoSegments)
        let rawTimes = boundarySeconds
            .map { CMTime(seconds: $0, preferredTimescale: timeScale) }
            .sorted(by: { $0 < $1 })
        var times: [CMTime] = []
        times.reserveCapacity(rawTimes.count)
        for t in rawTimes {
            if let last = times.last, last == t { continue }
            times.append(t)
        }

        let instructions: [AVMutableVideoCompositionInstruction] = zip(times, times.dropFirst()).compactMap { a, b in
            if b <= a { return nil }

            let midSeconds = (a.seconds + b.seconds) / 2
            let top = topmostSegment(at: midSeconds, segments: videoSegments)

            let instruction = AVMutableVideoCompositionInstruction()
            let startTime = a
            instruction.timeRange = CMTimeRangeFromTimeToTime(start: a, end: b)

            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)

            // Always emit layer instructions for every lane, and explicitly control opacity.
            // This avoids undefined behavior when multiple composition tracks exist.
            var layerInstructions: [AVVideoCompositionLayerInstruction] = []
            layerInstructions.reserveCapacity(compTracks.count)

            let chosenLaneIndex: Int?
            if let top {
                chosenLaneIndex = findLaneIndex(for: top, lanes: lanes)
            } else {
                chosenLaneIndex = nil
            }

            for (laneIndex, compTrack) in compTracks.enumerated() {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)

                if let chosenLaneIndex, chosenLaneIndex == laneIndex, let top {
                    layer.setOpacity(1.0, at: startTime)
                    // Apply project-canvas conform at the *current* instruction start time.
                    // Using .zero can leave later time slices untransformed (e.g. portrait videos become off-canvas).
                    let mode = clipConformById[top.clipId] ?? project.meta.spatialConformDefault
                    let t = spatialConformTransform(
                        naturalSize: top.naturalSize,
                        preferredTransform: top.preferredTransform,
                        renderSize: renderSize,
                        mode: mode
                    )
                    layer.setTransform(t, at: startTime)
                } else {
                    layer.setOpacity(0.0, at: startTime)
                }

                layerInstructions.append(layer)
            }

            instruction.layerInstructions = layerInstructions
            return instruction
        }

        if instructions.isEmpty {
            let debug = "Preview build: instructions empty"
            return PlayerItemBuildResult(item: AVPlayerItem(asset: composition), debug: debug)
        }

        videoComposition.instructions = instructions

        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition

        if let audioParams {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [audioParams]
            item.audioMix = audioMix
        }
        let totalDuration = videoSegments.map { $0.end }.max() ?? 0

        let videoTrackCount = composition.tracks(withMediaType: .video).count
        let probe = await probeFirstFrame(asset: composition, videoComposition: videoComposition, totalDuration: totalDuration)
        let debug = ([
            "Preview build: ok",
            "segments=\(videoSegments.count) lanes=\(lanes.count)",
            String(format: "duration=%.2fs fps=%.0f", totalDuration, project.meta.fps),
            "instructions=\(instructions.count)",
            "compositionVideoTracks=\(videoTrackCount)",
            probe,
            collected.warnings.isEmpty ? nil : ("warnings:\n" + collected.warnings.joined(separator: "\n"))
        ].compactMap { $0 }).joined(separator: "\n")

        return PlayerItemBuildResult(item: item, debug: debug)
    }

    private static func probeFirstFrame(
        asset: AVAsset,
        videoComposition: AVVideoComposition,
        totalDuration: Double
    ) async -> String? {
        // Run off main actor. We only need a quick signal for debugging.
        let t = min(max(0.1, totalDuration > 0 ? totalDuration * 0.1 : 0.1), max(0.1, totalDuration - 0.1))
        let time = CMTime(seconds: t, preferredTimescale: 600)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.videoComposition = videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        do {
            var actual = CMTime.zero
            let image = try gen.copyCGImage(at: time, actualTime: &actual)

            // Write a PNG for manual inspection.
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let outURL = tmp.appendingPathComponent("yunqi-probe-\(UUID().uuidString).png")
            let rep = NSBitmapImageRep(cgImage: image)
            let at = String(format: "%.3f", actual.seconds)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: outURL, options: [.atomic])
                return "probeFrame=ok size=\(image.width)x\(image.height) at=\(at) png=\(outURL.path)"
            }

            return "probeFrame=ok size=\(image.width)x\(image.height) at=\(at) png=(encode failed)"
        } catch {
            return "probeFrame=failed \(error.localizedDescription)"
        }
    }

    private struct CollectedSegments {
        var segments: [Segment]
        var warnings: [String]
    }

    private struct AudioSegment {
        let clipId: UUID
        let timelineTrackId: UUID
        let asset: AVAsset
        let assetAudioTrack: AVAssetTrack
        let start: Double
        let end: Double
        let sourceIn: Double
        let sourceDuration: Double
        let displayDuration: Double
    }

    private struct CollectedAudioSegments {
        var segments: [AudioSegment]
        var warnings: [String]
    }

    private static func collectAudioSegments(_ project: Project) async -> CollectedAudioSegments {
        var segments: [AudioSegment] = []
        var warnings: [String] = []

        for track in project.timeline.tracks where track.kind == .audio {
            for clip in track.clips {
                guard let assetRecord = project.mediaAssets.first(where: { $0.id == clip.assetId }) else { continue }
                let url = URL(fileURLWithPath: assetRecord.originalPath)
                let asset = AVURLAsset(url: url)

                do {
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    guard let audioTrack = tracks.first else {
                        warnings.append("No audio track: \(url.lastPathComponent)")
                        continue
                    }

                    let start = max(0, clip.timelineStartSeconds)
                    let displayDuration = max(0.05, clip.durationSeconds)

                    // Match video interpretation: displayDuration seconds on timeline consumes displayDuration * speed from source.
                    let speed = clip.speed
                    let sourceDuration = max(0.05, displayDuration * max(0.0001, speed))
                    let sourceIn = max(0, clip.sourceInSeconds)
                    let end = start + displayDuration

                    segments.append(
                        AudioSegment(
                            clipId: clip.id,
                            timelineTrackId: track.id,
                            asset: asset,
                            assetAudioTrack: audioTrack,
                            start: start,
                            end: end,
                            sourceIn: sourceIn,
                            sourceDuration: sourceDuration,
                            displayDuration: displayDuration
                        )
                    )
                } catch {
                    warnings.append("Load audio tracks failed: \(url.lastPathComponent) \(error.localizedDescription)")
                    continue
                }
            }
        }

        return CollectedAudioSegments(segments: segments, warnings: warnings)
    }

    private static func collectVideoSegments(_ project: Project) async -> CollectedSegments {
        var segments: [Segment] = []
        var warnings: [String] = []

        // Track order defines z-order: later tracks are on top.
        for (trackIndex, track) in project.timeline.tracks.enumerated() where track.kind == .video {
            let zBase = trackIndex * 1_000_000

            // Align adjacent boundaries within a small epsilon to reduce gaps/overlaps from floating-point math.
            var previousEndSeconds: Double? = nil

            for (clipIndex, clip) in track.clips.enumerated() {
                guard let assetRecord = project.mediaAssets.first(where: { $0.id == clip.assetId }) else { continue }
                let url = URL(fileURLWithPath: assetRecord.originalPath)
                let asset = AVURLAsset(url: url)

                do {
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard let videoTrack = tracks.first else {
                        warnings.append("No video track: \(url.lastPathComponent)")
                        continue
                    }

                    let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1280, height: 720)
                    let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity

                    var start = max(0, clip.timelineStartSeconds)
                    if let prev = previousEndSeconds, abs(start - prev) < 1e-6 {
                        start = prev
                    }
                    let displayDuration = max(0.05, clip.durationSeconds)

                // Interpret speed: timeline displays displayDuration seconds; source range consumes displayDuration * speed.
                let speed = clip.speed
                let sourceDuration = max(0.05, displayDuration * max(0.0001, speed))

                let sourceIn = max(0, clip.sourceInSeconds)
                let end = start + displayDuration
                previousEndSeconds = end

                    segments.append(
                        Segment(
                            clipId: clip.id,
                            asset: asset,
                            assetVideoTrack: videoTrack,
                            trackIndex: trackIndex,
                            start: start,
                            end: end,
                            sourceIn: sourceIn,
                            sourceDuration: sourceDuration,
                            displayDuration: displayDuration,
                            zIndex: zBase + clipIndex,
                            naturalSize: naturalSize,
                            preferredTransform: preferredTransform
                        )
                    )
                } catch {
                    warnings.append("Load tracks failed: \(url.lastPathComponent) \(error.localizedDescription)")
                    continue
                }
            }
        }

        // Higher zIndex on top.
        return CollectedSegments(segments: segments.sorted { $0.zIndex < $1.zIndex }, warnings: warnings)
    }

    private static func collectBoundaries(_ segments: [Segment]) -> [Double] {
        let maxEnd = segments.map { $0.end }.max() ?? 0
        var times = Set(segments.flatMap { [$0.start, $0.end] })
        times.insert(0)
        times.insert(maxEnd)
        return times.sorted()
    }

    private static func topmostSegment(at t: Double, segments: [Segment]) -> Segment? {
        // pick max zIndex among segments that cover t
        var best: Segment?
        for s in segments {
            if s.start - 1e-9 <= t, t < s.end - 1e-9 {
                if let b = best {
                    if s.zIndex >= b.zIndex {
                        best = s
                    }
                } else {
                    best = s
                }
            }
        }
        return best
    }

    private static func findLaneIndex(for target: Segment, lanes: [[Segment]]) -> Int? {
        for (i, lane) in lanes.enumerated() {
            if lane.contains(where: { $0.clipId == target.clipId }) {
                return i
            }
        }
        return nil
    }

    private static func fingerprint(_ project: Project) -> Int {
        // Cheap fingerprint: enough to trigger rebuild when timeline changes.
        var h = Hasher()
        h.combine(project.meta.fps)
        h.combine(project.meta.formatPolicy)
        h.combine(project.meta.renderSize.width)
        h.combine(project.meta.renderSize.height)
        h.combine(project.meta.spatialConformDefault)
        h.combine(project.mediaAssets.count)
        for a in project.mediaAssets {
            h.combine(a.id)
            h.combine(a.originalPath)
        }
        h.combine(project.timeline.tracks.count)
        for t in project.timeline.tracks {
            h.combine(t.id)
            h.combine(t.kind)
            h.combine(t.clips.count)
            for c in t.clips {
                h.combine(c.id)
                h.combine(c.assetId)
                h.combine(c.timelineStartSeconds)
                h.combine(c.sourceInSeconds)
                h.combine(c.durationSeconds)
                h.combine(c.speed)
                h.combine(c.volume)
                h.combine(c.spatialConformOverride)
            }
        }
        return h.finalize()
    }
}

private extension CGSize {
    var absoluteSize: CGSize {
        CGSize(width: abs(width), height: abs(height))
    }
}
