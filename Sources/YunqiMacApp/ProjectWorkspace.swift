import EditorCore
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

    @Published var previewTimeSeconds: Double = 0
    @Published var previewDebug: String = ""
    @Published var previewPlayTapCount: Int = 0
    @Published var previewFrameImage: CGImage? = nil
    @Published var previewFrameCount: Int = 0
    @Published var previewFrameSizeText: String = ""

    @Published var isPreviewLooping: Bool = false

    @Published var isExporting: Bool = false
    @Published var exportProgress: Double = 0
    @Published var exportStatusText: String = ""

    private var previewLastFrameAt: Date? = nil

    private var previewRateBeforeScrub: Float = 0

    let preview: PreviewPlayerController = PreviewPlayerController()

    private let projectStore: ProjectStore
    private var playbackConfigured = false
    private var previewConfigured = false
    private var previewCancellable: AnyCancellable?
    private var dirtyCancellable: AnyCancellable?
    private var lastSavedFingerprint: Data = Data()

    init(projectStore: ProjectStore = JSONProjectStore()) {
        self.projectStore = projectStore

        let project = Self.makeDefaultProject(name: "Yunqi", fps: 30)
        let session = EditorSession(project: project)
        self.store = EditorSessionStore(session: session)
        self.projectURL = nil

        self.lastSavedFingerprint = Self.fingerprint(project)
        self.isDirty = false
        startDirtyTracking()
    }

    var windowTitle: String {
        if let projectURL {
            return projectURL.lastPathComponent
        }
        return "Yunqi"
    }

    // MARK: - File

    func newProject(name: String = "Yunqi", fps: Double = 30) {
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
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.nameFieldStringValue = "Yunqi Export.mp4"

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await self.exportVideo(to: url)
            }
        }
    }

    func exportVideo(to url: URL) async {
        if isExporting {
            NSSound.beep()
            return
        }
        isExporting = true
        exportProgress = 0
        exportStatusText = "Exporting…"

        do {
            try await preview.export(
                project: store.project,
                to: url,
                presetName: AVAssetExportPresetHighestQuality,
                fileType: .mp4,
                onProgress: { [weak self] p in
                    Task { @MainActor in
                        self?.exportProgress = p
                    }
                }
            )
            exportProgress = 1
            exportStatusText = "Exported: \(url.lastPathComponent)"
            NSLog("[Export] Completed: %@", url.path)
        } catch {
            exportStatusText = "Export failed: \(error.localizedDescription)"
            NSLog("[Export] Failed: %@", String(describing: error))
            NSSound.beep()
        }

        isExporting = false
    }

    // MARK: - Basic actions

    func addVideoTrack() {
        Task { await store.addTrack(kind: .video) }
    }

    func addAssetToTimeline(assetId: UUID, preferredDurationSeconds: Double = 3.0) {
        Task {
            // Ensure there is at least one video track.
            if !store.project.timeline.tracks.contains(where: { $0.kind == .video }) {
                await store.addTrack(kind: .video)
            }

            guard let videoTrackIndex = store.project.timeline.tracks.firstIndex(where: { $0.kind == .video }) else {
                return
            }

            // Append at end of that track.
            let clips = store.project.timeline.tracks[videoTrackIndex].clips
            let endTime = clips.map { $0.timelineStartSeconds + $0.durationSeconds }.max() ?? 0

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

            do {
                try await store.addClip(
                    trackIndex: videoTrackIndex,
                    assetId: assetId,
                    timelineStartSeconds: endTime,
                    sourceInSeconds: 0,
                    durationSeconds: durationSeconds,
                    speed: 1.0
                )
            } catch {
                NSLog("Add clip failed: \(error)")
                NSSound.beep()
            }
        }
    }

    func undo() {
        Task { await store.undo() }
    }

    func redo() {
        Task { await store.redo() }
    }
}

enum WorkspaceError: Error {
    case missingProjectURL
}
