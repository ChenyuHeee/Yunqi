import EditorCore
import EditorEngine
import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
import RenderEngine
import Storage
import SwiftUI
import UIBridge
import UniformTypeIdentifiers

@MainActor
final class ProjectWorkspace: ObservableObject {
    let id: UUID = UUID()

    @Published private(set) var store: EditorSessionStore
    @Published private(set) var projectURL: URL?

    @Published private(set) var isDirty: Bool = false

    var canUndo: Bool { store.canUndo }
    var canRedo: Bool { store.canRedo }
    var undoActionName: String? { store.undoActionName }
    var redoActionName: String? { store.redoActionName }

    @Published var previewTimeSeconds: Double = 0
    @Published var previewDebug: String = ""

    // MARK: - Timeline display

    @Published var isAudioComponentsExpanded: Bool = true

    func toggleAudioComponentsExpanded() {
        isAudioComponentsExpanded.toggle()
    }
    @Published var previewPlayTapCount: Int = 0
    @Published var previewFrameImage: CGImage? = nil
    @Published var previewPixelBuffer: CVPixelBuffer? = nil
    @Published var previewPreferredTransform: CGAffineTransform = .identity
    @Published var previewFrameCount: Int = 0
    @Published var previewFrameSizeText: String = ""

    @Published var isPreviewLooping: Bool = false

    @Published var isExporting: Bool = false
    @Published var exportProgress: Double = 0
    @Published var exportStatusText: String = ""

    @Published var isExportDialogPresented: Bool = false
    @Published var exportDialogOutputURL: URL? = nil

    private let exportQueue: ExportQueue
    private var currentExportJobId: UUID? = nil

    // MARK: - Timeline selection (for menu commands)

    @Published var selectedClipIds: Set<UUID> = []
    @Published var primarySelectedClipId: UUID? = nil

    // MARK: - Timeline range selection (Final Cut-style)

    @Published var rangeInSeconds: Double? = nil
    @Published var rangeOutSeconds: Double? = nil

    var normalizedRange: (inSeconds: Double, outSeconds: Double)? {
        guard let a = rangeInSeconds, let b = rangeOutSeconds else { return nil }
        let lo = max(0, min(a, b))
        let hi = max(0, max(a, b))
        if hi - lo < 1e-9 { return nil }
        return (lo, hi)
    }

    var hasRangeSelection: Bool { normalizedRange != nil }

    private var previewLastFrameAt: Date? = nil

    private var previewRateBeforeScrub: Float = 0

    let preview: PreviewPlayerController = PreviewPlayerController()

    private let projectStore: ProjectStore
    private var playbackConfigured = false
    private var previewConfigured = false
    private var previewCancellable: AnyCancellable?
    private var dirtyCancellable: AnyCancellable?
    private var lastSavedFingerprint: Data = Data()

    private static let isMetalPreviewEnabled: Bool = {
        // Default to Metal for Apple Silicon-first performance & consistency.
        // Allow forcing the legacy path via env var for debugging/compat.
        let env = ProcessInfo.processInfo.environment["YUNQI_PREVIEW_RENDERER"]?.lowercased()
        if env == "avfoundation" || env == "legacy" || env == "player" {
            return false
        }
        return true
    }()

    init(projectStore: ProjectStore = JSONProjectStore()) {
        self.projectStore = projectStore

        self.exportQueue = ExportQueue(executor: Self.makeExportExecutor())

        let project = Self.makeDefaultProject(name: L("app.name"), fps: 30)
        let session = EditorSession(project: project)
        self.store = EditorSessionStore(session: session)
        self.projectURL = nil

        self.lastSavedFingerprint = Self.fingerprint(project)
        self.isDirty = false
        startDirtyTracking()
    }

    private static func makeExportExecutor() -> any ExportExecutor {
        let env = ProcessInfo.processInfo.environment["YUNQI_EXPORT_EXECUTOR"]?.lowercased()
        if env == "writer" {
            return AVAssetWriterExecutor()
        }
        return AVAssetExportSessionExecutor()
    }

    func updateTimelineSelection(selected: Set<UUID>, primary: UUID?) {
        selectedClipIds = selected
        primarySelectedClipId = primary
    }

    func updateTimelineRange(inSeconds: Double?, outSeconds: Double?) {
        rangeInSeconds = inSeconds
        rangeOutSeconds = outSeconds
    }

    func clearTimelineRange() {
        rangeInSeconds = nil
        rangeOutSeconds = nil
    }

    func clearTimelineSelection() {
        selectedClipIds.removeAll()
        primarySelectedClipId = nil
    }

    func selectAllTimelineClips() {
        let allClips: [Clip] = store.project.timeline.tracks.flatMap { $0.clips }
        guard !allClips.isEmpty else {
            clearTimelineSelection()
            return
        }

        let ordered = allClips.sorted {
            if $0.timelineStartSeconds != $1.timelineStartSeconds {
                return $0.timelineStartSeconds < $1.timelineStartSeconds
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        selectedClipIds = Set(ordered.map { $0.id })
        if let primary = primarySelectedClipId, selectedClipIds.contains(primary) {
            // keep
        } else {
            primarySelectedClipId = ordered.first?.id
        }
    }

    var windowTitle: String {
        if let projectURL {
            return projectURL.lastPathComponent
        }
        return L("app.name")
    }

    // MARK: - File

    func newProject(name: String = L("app.name"), fps: Double = 30) {
        let project = Self.makeDefaultProject(name: name, fps: fps)
        let session = EditorSession(project: project)
        self.store = EditorSessionStore(session: session)
        self.projectURL = nil
        self.playbackConfigured = false
        self.previewConfigured = false
        self.previewCancellable = nil

        self.lastSavedFingerprint = Self.fingerprint(project)
        self.isDirty = false
        startDirtyTracking()
    }

    func openProject(url: URL) throws {
        let project = try projectStore.load(from: url)
        let session = EditorSession(project: project)
        self.store = EditorSessionStore(session: session)
        self.projectURL = url
        self.playbackConfigured = false
        self.previewConfigured = false
        self.previewCancellable = nil

        self.lastSavedFingerprint = Self.fingerprint(project)
        self.isDirty = false
        startDirtyTracking()
    }

    /// Save if possible; otherwise prompt Save As.
    /// Returns true if the project is saved, false if user cancelled or save failed.
    func saveOrPromptSaveAs() -> Bool {
        do {
            try saveProject()
            return true
        } catch {
            return presentSavePanel()
        }
    }

    func configurePlaybackIfNeeded() {
        guard !playbackConfigured else { return }
        playbackConfigured = true
        Task { await store.configurePlayback(engine: NoopRenderEngine()) }
    }

    func configurePreviewIfNeeded() {
        guard !previewConfigured else { return }
        previewConfigured = true

        NSLog("[Preview] configurePreviewIfNeeded")

        preview.onDebug = { [weak self] text in
            self?.previewDebug = text
            NSLog("[Preview] %@", text)
        }
        previewDebug = "Preview configured"

        preview.startTimeUpdates { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.previewTimeSeconds = t
                self.handleLoopIfNeeded(currentSeconds: t)
            }
        }

        if Self.isMetalPreviewEnabled {
            preview.startVideoPixelBufferUpdates { [weak self] pb in
                guard let self else { return }
                self.previewPixelBuffer = pb
                self.previewPreferredTransform = self.preview.currentVideoPreferredTransform
                if let pb {
                    self.previewFrameCount += 1
                    self.previewFrameSizeText = "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"
                    self.previewLastFrameAt = Date()
                }
            }
        } else {
            preview.startVideoFrameUpdates { [weak self] frame in
                Task { @MainActor in
                    guard let self else { return }
                    self.previewFrameImage = frame
                    if frame != nil {
                        self.previewFrameCount += 1
                        if let frame {
                            self.previewFrameSizeText = "\(frame.width)x\(frame.height)"
                        }
                        let now = Date()
                        self.previewLastFrameAt = now
                        // Optional debug dump (disabled by default; can cause playback hitches).
                        if Self.isPreviewFrameDumpEnabled, self.previewFrameCount == 1, let frame {
                            self.saveOverlayFramePNGAsync(frame: frame, index: self.previewFrameCount)
                        }
                    }
                }
            }
        }

        // Initial build
        NSLog("[Preview] initial updateProject")
        preview.updateProject(store.project, preserveTime: false)

        // Rebuild when project changes (move/trim/import/add-clip).
        previewCancellable = store.$project
            .sink { [weak self] project in
                self?.preview.updateProject(project)
            }
    }

    var previewLastFrameAgeText: String {
        guard let t = previewLastFrameAt else { return "never" }
        let age = Date().timeIntervalSince(t)
        if age < 0 { return "0.00s" }
        return String(format: "%.2fs", age)
    }

    private static let isPreviewFrameDumpEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["YUNQI_DUMP_PREVIEW_FRAMES"] == "1"
    }()

    private func saveOverlayFramePNGAsync(frame: CGImage, index: Int) {
        let url = URL(fileURLWithPath: "/tmp/yunqi-overlay-frame-\(index).png")
        DispatchQueue.global(qos: .utility).async {
            guard let data = Self.pngData(from: frame) else {
                NSLog("[Preview] Failed to encode overlay frame as PNG")
                return
            }
            do {
                try data.write(to: url, options: [.atomic])
                NSLog("[Preview] Saved overlay frame PNG: %@", url.path)
            } catch {
                NSLog("[Preview] Failed to write overlay frame PNG: %@ error=%@", url.path, String(describing: error))
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

    // MARK: - Preview controls

    func playPreview() {
        configurePreviewIfNeeded()
        previewPlayTapCount += 1
        NSLog("[Preview] Play tapped taps=%d", previewPlayTapCount)
        // 先 play() 让 player.rate>0，随后 updateProject 完成后会自动继续播放。
        preview.play()
        preview.updateProject(store.project, preserveTime: true)
    }

    func pausePreview() {
        NSLog("[Preview] Pause tapped")
        preview.pause()
    }

    func stopPreview() {
        NSLog("[Preview] Stop tapped")
        preview.stop()
    }

    func seekPreview(to seconds: Double) {
        preview.seek(seconds: seconds)
    }

    func setPreviewRate(_ rate: Float) {
        configurePreviewIfNeeded()
        NSLog("[Preview] Set rate=%.2f", rate)
        preview.setRate(rate)
        preview.updateProject(store.project, preserveTime: true)
    }

    func beginScrubPreview() {
        configurePreviewIfNeeded()
        previewRateBeforeScrub = preview.currentRequestedRate
        if previewRateBeforeScrub != 0 {
            preview.pause()
        }
    }

    func endScrubPreview() {
        let r = previewRateBeforeScrub
        previewRateBeforeScrub = 0
        if r != 0 {
            preview.setRate(r)
        }
    }

    private func handleLoopIfNeeded(currentSeconds t: Double) {
        guard isPreviewLooping else { return }
        let r = preview.currentRequestedRate
        guard r != 0 else { return }

        let duration = projectDurationSeconds
        guard duration > 0 else { return }

        // 在尾部附近回环（避免时间观察者的抖动/越界）。
        if t >= max(0, duration - 0.03) {
            preview.seek(seconds: 0) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    // seek 后恢复原速率
                    self.preview.setRate(r)
                }
            }
        }
    }

    private var projectDurationSeconds: Double {
        store.project.timeline.tracks
            .flatMap { $0.clips }
            .map { $0.timelineStartSeconds + $0.durationSeconds }
            .max() ?? 0
    }

    func saveProject() throws {
        guard let projectURL else {
            throw WorkspaceError.missingProjectURL
        }
        try projectStore.save(store.project, to: projectURL)

        lastSavedFingerprint = Self.fingerprint(store.project)
        isDirty = false
    }

    func saveProjectAs(url: URL) throws {
        try projectStore.save(store.project, to: url)
        self.projectURL = url

        lastSavedFingerprint = Self.fingerprint(store.project)
        isDirty = false
    }

    // MARK: - Panels

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [] // allow any

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try openProject(url: url)
            } catch {
                NSLog("Open project failed: \(error)")
                NSSound.beep()
            }
        }
    }

    @discardableResult
    func presentSavePanel() -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? "project.json"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try saveProjectAs(url: url)
                return true
            } catch {
                NSLog("Save project failed: \(error)")
                NSSound.beep()
                return false
            }
        }

        return false
    }

    private func startDirtyTracking() {
        dirtyCancellable?.cancel()
        dirtyCancellable = store.$project
            .sink { [weak self] project in
                guard let self else { return }
                self.isDirty = Self.fingerprint(project) != self.lastSavedFingerprint
            }
    }

    private static func makeDefaultProject(name: String, fps: Double) -> Project {
        let defaultTimeline = Timeline(tracks: [Track(kind: .video)])
        return Project(meta: ProjectMeta(name: name, fps: fps), timeline: defaultTimeline)
    }

    private static func fingerprint(_ project: Project) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(project)) ?? Data()
    }

    func presentImportMediaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            Task {
                for url in panel.urls {
                    _ = await store.importAsset(path: url.path)
                }
            }
        }
    }

    func presentExportPanel() {
        // Legacy entry point: keep the name but show the new export dialog.
        isExportDialogPresented = true
    }

    func chooseExportDialogOutputURL() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.nameFieldStringValue = "Yunqi Export.mp4"

        if panel.runModal() == .OK, let url = panel.url {
            exportDialogOutputURL = url
        }
    }

    func startExportFromDialog() {
        guard let url = exportDialogOutputURL else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            await self.exportVideo(to: url)
        }
    }

    func cancelCurrentExport() {
        guard let jobId = currentExportJobId else {
            NSSound.beep()
            return
        }
        exportQueue.cancel(jobId: jobId)
    }

    func exportVideo(to url: URL) async {
        if isExporting {
            NSSound.beep()
            return
        }

        // Capture a stable project snapshot at enqueue time.
        let job = ExportJob(
            project: store.project,
            outputURL: url,
            presetName: AVAssetExportPresetHighestQuality,
            fileTypeIdentifier: AVFileType.mp4.rawValue
        )
        currentExportJobId = job.id

        exportProgress = 0
        exportStatusText = L("status.exporting")
        isExporting = true

        exportQueue.enqueue(job)

        // Poll queue state to update the existing toolbar/status fields.
        // (We also show a dedicated export dialog; these fields remain as global status.)
        while exportQueue.isRunning || exportQueue.hasQueued {
            if let p = exportQueue.currentProgress {
                exportProgress = p
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Resolve final state of the just-enqueued job.
        if let item = exportQueue.items.first(where: { $0.job.id == job.id }) {
            switch item.state {
            case .completed:
                exportProgress = 1
                exportStatusText = String(format: L("status.exported"), url.lastPathComponent)
                NSLog("[Export] Completed: %@", url.path)
            case let .failed(message):
                exportStatusText = String(format: L("status.exportFailed"), message)
                NSLog("[Export] Failed: %@", message)
                NSSound.beep()
            case .cancelled:
                exportStatusText = L("status.exportCancelled")
            case .queued, .running:
                // Should not happen after the loop; keep a safe fallback.
                exportStatusText = String(format: L("status.exportFailed"), "Unexpected export state")
            }
        }

        isExporting = false
        if currentExportJobId == job.id {
            currentExportJobId = nil
        }
    }

    // MARK: - Basic actions

    func addVideoTrack() {
        Task { await store.addTrack(kind: .video) }
    }

    func addAudioTrack() {
        Task { await store.addTrack(kind: .audio) }
    }

    func addAssetToTimeline(assetId: UUID, preferredDurationSeconds: Double = 3.0) {
        addAssetToTimeline(assetId: assetId, at: nil, targetTrackIndex: nil, preferredDurationSeconds: preferredDurationSeconds)
    }

    func addAssetToTimeline(
        assetId: UUID,
        at timelineStartSeconds: Double?,
        targetTrackIndex: Int?,
        preferredDurationSeconds: Double = 3.0
    ) {
        Task { @MainActor in
            // Decide target track kind based on the asset.
            var targetKind: TrackKind = .video
            var autoLockRenderSize: RenderSize? = nil
            var autoLockFPS: Double? = nil
            if let record = store.project.mediaAssets.first(where: { $0.id == assetId }) {
                let url = URL(fileURLWithPath: record.originalPath)
                let asset = AVURLAsset(url: url)

                // IMPORTANT: be conservative. Only treat as audio-only when we can *successfully* confirm
                // there is no video track but there is audio. If probing video tracks fails, keep default .video.
                do {
                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    if videoTracks.isEmpty {
                        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                        if !audioTracks.isEmpty {
                            targetKind = .audio
                        }
                    } else {
                        // Final Cut Pro-like Automatic Settings: lock project format on the first valid video.
                        if store.project.meta.formatPolicy == .automatic {
                            let hasAnyVideoClip = store.project.timeline.tracks
                                .filter { $0.kind == .video }
                                .flatMap { $0.clips }
                                .isEmpty == false

                            if !hasAnyVideoClip, let first = videoTracks.first {
                                let naturalSize = (try? await first.load(.naturalSize)) ?? .zero
                                let preferredTransform = (try? await first.load(.preferredTransform)) ?? .identity
                                let display = naturalSize.applying(preferredTransform)
                                let w = Int((abs(display.width)).rounded())
                                let h = Int((abs(display.height)).rounded())
                                if w > 0, h > 0 {
                                    autoLockRenderSize = RenderSize(width: w, height: h)
                                }

                                // Try to lock fps (Final Cut Pro Automatic Settings).
                                // Prefer nominalFrameRate; fallback to minFrameDuration.
                                let nominal = Double((try? await first.load(.nominalFrameRate)) ?? 0)
                                let minFrameDuration = (try? await first.load(.minFrameDuration))

                                var rawFps: Double = 0
                                if nominal.isFinite, nominal > 1 {
                                    rawFps = nominal
                                } else if let d = minFrameDuration {
                                    let s = d.seconds
                                    if s.isFinite, s > 0.000001 {
                                        rawFps = 1.0 / s
                                    }
                                }

                                autoLockFPS = Self.normalizeFPS(rawFps)
                            }
                        }
                    }
                } catch {
                    // Keep .video (default) on probe failures.
                }
            }

            // Prefer using full asset duration if available.
            var durationSeconds = preferredDurationSeconds
            if let record = store.project.mediaAssets.first(where: { $0.id == assetId }) {
                let url = URL(fileURLWithPath: record.originalPath)
                let asset = AVURLAsset(url: url)
                if let d = try? await asset.load(.duration) {
                    let seconds = d.seconds
                    if seconds.isFinite, seconds > 0 {
                        durationSeconds = seconds
                        NSLog(
                            "[Timeline] Using asset duration: %.3fs (preferred=%.3fs) asset=%@",
                            durationSeconds,
                            preferredDurationSeconds,
                            url.lastPathComponent
                        )
                    } else {
                        NSLog(
                            "[Timeline] Asset duration invalid (%.3fs). Fallback to preferred=%.3fs asset=%@",
                            seconds,
                            preferredDurationSeconds,
                            url.lastPathComponent
                        )
                    }
                } else {
                    NSLog(
                        "[Timeline] Failed to load asset duration. Fallback to preferred=%.3fs asset=%@",
                        preferredDurationSeconds,
                        url.lastPathComponent
                    )
                }
            }

            // Work off a stable snapshot. NOTE: EditorSessionStore.project updates via an async stream,
            // so we must not rely on it being updated immediately after await store.addTrack.
            var tracks = store.project.timeline.tracks

            func overlaps(_ startSeconds: Double, _ durationSeconds: Double, in track: Track) -> Bool {
                let eps = 1e-9
                let a0 = startSeconds
                let a1 = startSeconds + max(0, durationSeconds)
                for c in track.clips {
                    let b0 = c.timelineStartSeconds
                    let b1 = c.timelineStartSeconds + c.durationSeconds
                    if a0 < b1 - eps && a1 > b0 + eps { return true }
                }
                return false
            }

            // Ensure there is at least one track of the target kind.
            if !tracks.contains(where: { $0.kind == targetKind }) {
                await store.addTrack(kind: targetKind)
                // Mirror the structural change locally (empty track) for subsequent decisions.
                tracks.append(Track(kind: targetKind))
            }

            // Decide which track to place the NEW clip on.
            var chosenTrackIndex: Int = 0

            let candidates = tracks.indices.filter { tracks[$0].kind == targetKind }
            let firstSameKind = candidates.first ?? 0

            if let t0 = timelineStartSeconds {
                let start = max(0, t0)

                if
                    let targetTrackIndex,
                    tracks.indices.contains(targetTrackIndex),
                    tracks[targetTrackIndex].kind == targetKind
                {
                    if !overlaps(start, durationSeconds, in: tracks[targetTrackIndex]) {
                        chosenTrackIndex = targetTrackIndex
                    } else if let idx = candidates.first(where: { $0 != targetTrackIndex && !overlaps(start, durationSeconds, in: tracks[$0]) }) {
                        chosenTrackIndex = idx
                    } else {
                        let newIndex = tracks.count
                        await store.addTrack(kind: targetKind)
                        tracks.append(Track(kind: targetKind))
                        chosenTrackIndex = newIndex
                    }
                } else if let idx = candidates.first(where: { !overlaps(start, durationSeconds, in: tracks[$0]) }) {
                    chosenTrackIndex = idx
                } else {
                    let newIndex = tracks.count
                    await store.addTrack(kind: targetKind)
                    tracks.append(Track(kind: targetKind))
                    chosenTrackIndex = newIndex
                }
            } else if
                let targetTrackIndex,
                tracks.indices.contains(targetTrackIndex),
                tracks[targetTrackIndex].kind == targetKind
            {
                chosenTrackIndex = targetTrackIndex
            } else {
                chosenTrackIndex = firstSameKind
            }

            let finalStartSeconds: Double = {
                if let timelineStartSeconds { return max(0, timelineStartSeconds) }
                // Append at end of chosen track (based on snapshot).
                if tracks.indices.contains(chosenTrackIndex) {
                    let clips = tracks[chosenTrackIndex].clips
                    return clips.map { $0.timelineStartSeconds + $0.durationSeconds }.max() ?? 0
                }
                return 0
            }()

            do {
                try await store.addClip(
                    trackIndex: chosenTrackIndex,
                    assetId: assetId,
                    timelineStartSeconds: finalStartSeconds,
                    sourceInSeconds: 0,
                    durationSeconds: durationSeconds,
                    speed: 1.0,
                    autoLockProjectRenderSize: (targetKind == .video ? autoLockRenderSize : nil),
                    autoLockProjectFPS: (targetKind == .video ? autoLockFPS : nil)
                )
            } catch {
                NSLog("Add clip failed: \(error)")
                NSSound.beep()
            }
        }
    }

    private static func normalizeFPS(_ fps: Double) -> Double? {
        guard fps.isFinite, fps > 1 else { return nil }
        let candidates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
        var best: (value: Double, diff: Double)? = nil
        for c in candidates {
            let d = abs(c - fps)
            if best == nil || d < best!.diff { best = (c, d) }
        }
        if let best, best.diff <= 0.25 {
            return best.value
        }
        return fps
    }

    func undo() {
        Task { await store.undo() }
    }

    func redo() {
        Task { await store.redo() }
    }

    // MARK: - Asset actions (for sidebar)

    func renameAsset(assetId: UUID, displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSSound.beep()
            return
        }

        Task {
            do {
                try await store.renameAsset(assetId: assetId, displayName: trimmed)
            } catch {
                NSSound.beep()
            }
        }
    }

    // MARK: - Clip actions (for menu commands)

    private func targetClipIdsForSelection() -> [UUID] {
        let ids = selectedClipIds.union(primarySelectedClipId.map { [$0] } ?? [])
        return Array(ids)
    }

    func setProjectSpatialConformDefault(_ mode: SpatialConform) {
        Task {
            await store.setProjectSpatialConformDefault(mode)
        }
    }

    /// Set spatial conform override for current selection (or primary selection if no multi-selection).
    /// Pass nil to clear override (follow project default).
    func setSpatialConformOverrideForSelection(_ mode: SpatialConform?) {
        let ids = targetClipIdsForSelection()
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }

        Task {
            do {
                try await store.setClipsSpatialConformOverride(clipIds: ids, override: mode)
            } catch {
                NSSound.beep()
            }
        }
    }

    func setSpatialConformOverrideForPrimarySelection(_ mode: SpatialConform?) {
        guard let id = primarySelectedClipId else {
            NSSound.beep()
            return
        }
        Task {
            do {
                try await store.setClipSpatialConformOverride(clipId: id, override: mode)
            } catch {
                NSSound.beep()
            }
        }
    }

    var canAdjustClipVolumeAtPlayhead: Bool {
        clipIdForPrimaryOrPlayhead(timeSeconds: previewTimeSeconds) != nil
    }

    func adjustClipVolumeAtPlayhead(delta: Double) {
        let t = previewTimeSeconds
        guard let clipId = clipIdForPrimaryOrPlayhead(timeSeconds: t) else {
            NSSound.beep()
            return
        }

        let current = clipVolume(clipId: clipId) ?? 1.0
        let next = max(0, min(2.0, current + delta))

        Task {
            do {
                try await store.setClipVolume(clipId: clipId, volume: next)
            } catch {
                NSSound.beep()
            }
        }
    }

    var canToggleAudioTrackMuteSolo: Bool {
        targetTrackIdForPrimaryOrPlayhead(timeSeconds: previewTimeSeconds) != nil
    }

    func toggleMuteForTargetTrack() {
        let t = previewTimeSeconds
        guard let trackId = targetTrackIdForPrimaryOrPlayhead(timeSeconds: t) else {
            NSSound.beep()
            return
        }
        Task {
            do {
                try await store.toggleTrackMute(trackId: trackId)
            } catch {
                NSSound.beep()
            }
        }
    }

    func toggleSoloForTargetTrack() {
        let t = previewTimeSeconds
        guard let trackId = targetTrackIdForPrimaryOrPlayhead(timeSeconds: t) else {
            NSSound.beep()
            return
        }
        Task {
            do {
                try await store.toggleTrackSolo(trackId: trackId)
            } catch {
                NSSound.beep()
            }
        }
    }

    var canSplitAtPlayhead: Bool {
        let t = previewTimeSeconds

        // If there is a selection, allow blade if any selected clip can be split at the playhead.
        let selected = selectedClipIds.union(primarySelectedClipId.map { [$0] } ?? [])
        if !selected.isEmpty {
            for id in selected {
                if canSplitClip(clipId: id, at: t) { return true }
            }
            return false
        }

        // No selection: allow blade if there is any clip under the playhead.
        return clipIdIntersectingPlayhead(timeSeconds: t) != nil
    }

    /// Final Cut-style Blade (Cmd+B): blade selection if any; otherwise blade the clip under playhead.
    func bladeAtPlayhead() {
        let t = previewTimeSeconds

        let selected = selectedClipIds.union(primarySelectedClipId.map { [$0] } ?? [])
        if !selected.isEmpty {
            let eligible = selected.filter { canSplitClip(clipId: $0, at: t) }
            guard !eligible.isEmpty else {
                NSSound.beep()
                return
            }
            Task {
                await store.splitClips(clipIds: Array(eligible), at: t)
            }
            return
        }

        guard let clipId = clipIdIntersectingPlayhead(timeSeconds: t) else {
            NSSound.beep()
            return
        }
        Task {
            do {
                try await store.splitClip(clipId: clipId, at: t)
            } catch {
                NSSound.beep()
            }
        }
    }

    /// Final Cut-style Blade All (Shift+Cmd+B): blade every clip on every track that intersects playhead.
    func bladeAllAtPlayhead() {
        let t = previewTimeSeconds
        var ids: [UUID] = []
        for track in store.project.timeline.tracks {
            for clip in track.clips {
                let start = clip.timelineStartSeconds
                let end = start + clip.durationSeconds
                if t > start, t < end {
                    ids.append(clip.id)
                }
            }
        }
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        Task {
            await store.splitClips(clipIds: ids, at: t)
        }
    }

    private func canSplitClip(clipId: UUID, at timeSeconds: Double) -> Bool {
        for track in store.project.timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                let start = clip.timelineStartSeconds
                let end = start + clip.durationSeconds
                // Match EditorCore: must split strictly inside clip bounds.
                return timeSeconds > start && timeSeconds < end
            }
        }
        return false
    }

    private func clipIdForPrimaryOrPlayhead(timeSeconds t: Double) -> UUID? {
        if let primarySelectedClipId { return primarySelectedClipId }
        for track in store.project.timeline.tracks {
            for clip in track.clips {
                let start = clip.timelineStartSeconds
                let end = start + clip.durationSeconds
                guard t >= start, t <= end else { continue }
                return clip.id
            }
        }
        return nil
    }

    private func targetTrackIdForPrimaryOrPlayhead(timeSeconds t: Double) -> UUID? {
        if let primarySelectedClipId {
            for track in store.project.timeline.tracks {
                if track.clips.contains(where: { $0.id == primarySelectedClipId }) {
                    return track.id
                }
            }
        }
        for track in store.project.timeline.tracks {
            for clip in track.clips {
                let start = clip.timelineStartSeconds
                let end = start + clip.durationSeconds
                guard t >= start, t <= end else { continue }
                return track.id
            }
        }
        return nil
    }

    private func clipVolume(clipId: UUID) -> Double? {
        for track in store.project.timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                return clip.volume
            }
        }
        return nil
    }

    private func clipIdIntersectingPlayhead(timeSeconds t: Double) -> UUID? {
        for track in store.project.timeline.tracks {
            for clip in track.clips {
                let start = clip.timelineStartSeconds
                let end = start + clip.durationSeconds
                // Match EditorCore: must split strictly inside clip bounds.
                guard t > start, t < end else { continue }
                return clip.id
            }
        }
        return nil
    }

    func deleteSelectedClips(ripple: Bool) {
        let ids: [UUID]
        if !selectedClipIds.isEmpty {
            ids = Array(selectedClipIds)
        } else if let primarySelectedClipId {
            ids = [primarySelectedClipId]
        } else {
            NSSound.beep()
            return
        }

        Task {
            do {
                if ripple {
                    try await store.rippleDeleteClips(clipIds: ids)
                } else {
                    if ids.count == 1 {
                        try await store.deleteClip(clipId: ids[0])
                    } else {
                        try await store.deleteClips(clipIds: ids)
                    }
                }

                // Clear selection to avoid stale IDs after deletion.
                selectedClipIds.removeAll()
                primarySelectedClipId = nil
            } catch {
                NSSound.beep()
            }
        }
    }
}

enum WorkspaceError: Error {
    case missingProjectURL
}
