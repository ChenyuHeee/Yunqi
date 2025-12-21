import EditorCore
import AppKit
import AVKit
import RenderEngine
import Storage
import SwiftUI
import UIBridge
import UniformTypeIdentifiers

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[App] YunqiMacApp launched")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct YunqiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = ProjectWorkspace()

    var body: some Scene {
        WindowGroup(workspace.windowTitle) {
            ContentView()
                .environmentObject(workspace)
                .environmentObject(workspace.store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    workspace.newProject()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open…") {
                    workspace.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("Save") {
                    do {
                        try workspace.saveProject()
                    } catch {
                        // 没有路径则走另存为
                        workspace.presentSavePanel()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Save As…") {
                    workspace.presentSavePanel()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(after: .newItem) {
                Divider()
                Button("Import Media…") {
                    workspace.presentImportMediaPanel()
                }
                .keyboardShortcut("i", modifiers: [.command])
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    workspace.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])

                Button("Redo") {
                    workspace.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}

private struct ContentView: View {
    @EnvironmentObject private var workspace: ProjectWorkspace
    @EnvironmentObject private var store: EditorSessionStore

    var body: some View {
        HSplitView {
            SidebarView()
                // `HSplitView` can override child sizing; lock min/ideal/max to prevent collapsing.
                .frame(minWidth: 260, idealWidth: 260, maxWidth: 260)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(100)

            VSplitView {
                PreviewView()
                    .frame(minHeight: 260)
                    .layoutPriority(1)

                TimelineHostView()
                    .frame(minHeight: 260)
                    .layoutPriority(0)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .task {
            workspace.configurePlaybackIfNeeded()
            workspace.configurePreviewIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("Play") {
                    workspace.playPreview()
                }
                .disabled(workspace.isExporting)
                Button("Pause") {
                    workspace.pausePreview()
                }
                .disabled(workspace.isExporting)
                Button("Stop") {
                    workspace.stopPreview()
                }
                .disabled(workspace.isExporting)

                Button("Export…") {
                    workspace.presentExportPanel()
                }
                .disabled(workspace.isExporting)

                Toggle("Loop", isOn: $workspace.isPreviewLooping)

                if workspace.isExporting {
                    Text(String(format: "export %.0f%%", workspace.exportProgress * 100))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                } else if !workspace.exportStatusText.isEmpty {
                    Text(workspace.exportStatusText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .lineLimit(1)
                }

                Text(String(format: "t=%.2f rate=%.2f taps=%d item=%@",
                            workspace.previewTimeSeconds,
                            workspace.preview.player.rate,
                            workspace.previewPlayTapCount,
                            workspace.preview.player.currentItem == nil ? "nil" : "set"))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))

                Text("overlay: \(overlayStatusText) frames: \(workspace.previewFrameCount)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))

                Divider()

                Button("+ Video Track") {
                    workspace.addVideoTrack()
                }
            }
        }
    }

    private var overlayStatusText: String {
        (workspace.previewFrameImage == nil) ? "nil" : "set"
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var workspace: ProjectWorkspace
    @EnvironmentObject private var store: EditorSessionStore

    @State private var selectedAssetId: UUID?

    var body: some View {
        let project = store.project
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.meta.name)
                    .font(.headline)
                Text("FPS: \(project.meta.fps, specifier: "%.0f")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            GroupBox("Media") {
                if project.mediaAssets.isEmpty {
                    Text("No assets")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    List(project.mediaAssets, id: \.id, selection: $selectedAssetId) { asset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.originalPath)
                                .lineLimit(1)
                            Text(asset.id.uuidString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                HStack {
                    Button("Import Media…") {
                        workspace.presentImportMediaPanel()
                    }

                    Button("Add To Video Track") {
                        if let id = selectedAssetId {
                            workspace.addAssetToTimeline(assetId: id)
                        } else {
                            NSSound.beep()
                        }
                    }
                    .disabled(selectedAssetId == nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }

            GroupBox("Tracks") {
                if project.timeline.tracks.isEmpty {
                    Text("No tracks")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    List(Array(project.timeline.tracks.enumerated()), id: \.element.id) { index, track in
                        HStack {
                            Text("[\(index)] \(track.kind.rawValue)")
                            Spacer()
                            Text("clips: \(track.clips.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

private struct PreviewView: View {
    @EnvironmentObject private var workspace: ProjectWorkspace
    @EnvironmentObject private var store: EditorSessionStore

    var body: some View {
        ZStack {
            Rectangle().fill(.black)
            PlayerViewRepresentable(
                player: workspace.preview.player,
                overlayFrame: workspace.previewFrameImage
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let overlayFrame: CGImage?

    fileprivate final class PlayerContainerView: NSView {
        private var overlayFrame: CGImage? {
            didSet {
                needsDisplay = true
            }
        }

        override var isOpaque: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(bounds)

            guard let cg = overlayFrame else { return }

            // Fit image aspect into bounds.
            let imgW = CGFloat(cg.width)
            let imgH = CGFloat(cg.height)
            guard imgW > 0, imgH > 0, bounds.width > 0, bounds.height > 0 else { return }

            let scale = min(bounds.width / imgW, bounds.height / imgH)
            let drawW = imgW * scale
            let drawH = imgH * scale
            let x = (bounds.width - drawW) / 2
            let y = (bounds.height - drawH) / 2
            let dest = CGRect(x: x, y: y, width: drawW, height: drawH)

            ctx.interpolationQuality = .high
            ctx.draw(cg, in: dest)
        }

        func setOverlay(frame: CGImage?) {
            overlayFrame = frame
        }
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.setOverlay(frame: overlayFrame)
        return v
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.setOverlay(frame: overlayFrame)
    }
}



private struct TimelineHostView: View {
    @EnvironmentObject private var workspace: ProjectWorkspace
    @EnvironmentObject private var store: EditorSessionStore

    var body: some View {
        TimelineRepresentable(
            project: store.project,
            playheadSeconds: workspace.previewTimeSeconds,
            playerRate: workspace.preview.player.rate,
            onMoveClipCommitted: { clipId, newStartSeconds in
                Task {
                    do {
                        try await store.moveClip(clipId: clipId, toStartSeconds: newStartSeconds)
                    } catch {
                        NSSound.beep()
                    }
                }
            },
            onTrimClipCommitted: { clipId, newTimelineStartSeconds, newSourceInSeconds, newDurationSeconds in
                Task {
                    do {
                        try await store.trimClip(
                            clipId: clipId,
                            newTimelineStartSeconds: newTimelineStartSeconds,
                            newSourceInSeconds: newSourceInSeconds,
                            newDurationSeconds: newDurationSeconds
                        )
                    } catch {
                        NSSound.beep()
                    }
                }
            }
            ,
            onScrubBegan: {
                workspace.beginScrubPreview()
            },
            onScrubEnded: {
                workspace.endScrubPreview()
            },
            onSeekRequested: { seconds in
                workspace.seekPreview(to: seconds)
            },
            onSetPlaybackRateRequested: { rate in
                workspace.setPreviewRate(rate)
            }
        )
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TimelineRepresentable: NSViewRepresentable {
    let project: Project
    let playheadSeconds: Double
    let playerRate: Float
    let onMoveClipCommitted: (UUID, Double) -> Void
    let onTrimClipCommitted: (UUID, Double?, Double?, Double?) -> Void
    let onScrubBegan: () -> Void
    let onScrubEnded: () -> Void
    let onSeekRequested: (Double) -> Void
    let onSetPlaybackRateRequested: (Float) -> Void

    func makeNSView(context: Context) -> TimelineNSView {
        let view = TimelineNSView()
        view.onMoveClipCommitted = onMoveClipCommitted
        view.onTrimClipCommitted = onTrimClipCommitted
        view.onScrubBegan = onScrubBegan
        view.onScrubEnded = onScrubEnded
        view.onSeekRequested = onSeekRequested
        view.onSetPlaybackRateRequested = onSetPlaybackRateRequested
        return view
    }

    func updateNSView(_ nsView: TimelineNSView, context: Context) {
        nsView.project = project
        nsView.playheadSeconds = playheadSeconds
        nsView.playerRate = playerRate
        nsView.onMoveClipCommitted = onMoveClipCommitted
        nsView.onTrimClipCommitted = onTrimClipCommitted
        nsView.onScrubBegan = onScrubBegan
        nsView.onScrubEnded = onScrubEnded
        nsView.onSeekRequested = onSeekRequested
        nsView.onSetPlaybackRateRequested = onSetPlaybackRateRequested
        nsView.needsDisplay = true
    }
}

private final class TimelineNSView: NSView {
    var project: Project = Project(meta: ProjectMeta(name: "Yunqi"))
    var playheadSeconds: Double = 0
    var playerRate: Float = 0
    var onMoveClipCommitted: ((UUID, Double) -> Void)?
    var onTrimClipCommitted: ((UUID, Double?, Double?, Double?) -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?
    var onSeekRequested: ((Double) -> Void)?
    var onSetPlaybackRateRequested: ((Float) -> Void)?

    private var selectedClipId: UUID?
    private var dragging: DragState?
    private var scrubbing: ScrubState?
    private var scrubPreviewSeconds: Double?
    private var dragPreviewStartSeconds: [UUID: Double] = [:]
    private var dragPreviewDurationSeconds: [UUID: Double] = [:]
    private var dragPreviewSourceInSeconds: [UUID: Double] = [:]

    private enum DragMode {
        case move
        case trimLeft
        case trimRight
    }

    private struct DragState {
        let clipId: UUID
        let trackId: UUID
        let mode: DragMode
        let originalStartSeconds: Double
        let originalSourceInSeconds: Double
        let originalDurationSeconds: Double
        let mouseDownPoint: CGPoint
    }

    private struct ScrubState {
        let mouseDownPoint: CGPoint
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hitTestClip(at: point) {
            selectedClipId = hit.clipId

            let mode: DragMode
            if hit.isNearLeftEdge {
                mode = .trimLeft
            } else if hit.isNearRightEdge {
                mode = .trimRight
            } else {
                mode = .move
            }

            dragging = DragState(
                clipId: hit.clipId,
                trackId: hit.trackId,
                mode: mode,
                originalStartSeconds: hit.startSeconds,
                originalSourceInSeconds: hit.sourceInSeconds,
                originalDurationSeconds: hit.durationSeconds,
                mouseDownPoint: point
            )
            scrubbing = nil
            scrubPreviewSeconds = nil
        } else {
            selectedClipId = nil
            dragging = nil
            dragPreviewStartSeconds.removeAll()
            dragPreviewDurationSeconds.removeAll()
            dragPreviewSourceInSeconds.removeAll()

            // 点击空白区域（lane）进行 scrub。
            if point.x >= laneX {
                onScrubBegan?()
                scrubbing = ScrubState(mouseDownPoint: point)
                let s = seconds(atX: point.x)
                scrubPreviewSeconds = s
                onSeekRequested?(s)
            } else {
                scrubbing = nil
                scrubPreviewSeconds = nil
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let scrubbing {
            let point = convert(event.locationInWindow, from: nil)
            let s = seconds(atX: point.x)
            scrubPreviewSeconds = s
            onSeekRequested?(s)
            needsDisplay = true
            _ = scrubbing
            return
        }

        guard let dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragging.mouseDownPoint.x
        let deltaSeconds = Double(dx / pxPerSecond)

        switch dragging.mode {
        case .move:
            let proposed = dragging.originalStartSeconds + deltaSeconds
            dragPreviewStartSeconds[dragging.clipId] = max(0, proposed)

        case .trimLeft:
            let originalStart = dragging.originalStartSeconds
            let originalSourceIn = dragging.originalSourceInSeconds
            let originalDuration = dragging.originalDurationSeconds

            let endSeconds = originalStart + originalDuration
            var proposedStart = originalStart + deltaSeconds
            proposedStart = max(0, proposedStart)
            proposedStart = min(proposedStart, endSeconds - minClipDurationSeconds)

            let newDuration = max(minClipDurationSeconds, endSeconds - proposedStart)
            let newSourceIn = max(0, originalSourceIn + (proposedStart - originalStart))

            dragPreviewStartSeconds[dragging.clipId] = proposedStart
            dragPreviewDurationSeconds[dragging.clipId] = newDuration
            dragPreviewSourceInSeconds[dragging.clipId] = newSourceIn

        case .trimRight:
            let originalStart = dragging.originalStartSeconds
            let originalDuration = dragging.originalDurationSeconds
            let originalEnd = originalStart + originalDuration
            var proposedEnd = originalEnd + deltaSeconds
            proposedEnd = max(proposedEnd, originalStart + minClipDurationSeconds)

            let newDuration = max(minClipDurationSeconds, proposedEnd - originalStart)
            dragPreviewDurationSeconds[dragging.clipId] = newDuration
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if scrubbing != nil {
            scrubbing = nil
            scrubPreviewSeconds = nil
            onScrubEnded?()
            needsDisplay = true
            return
        }

        guard let dragging else { return }
        defer {
            self.dragging = nil
            self.dragPreviewStartSeconds.removeAll()
            self.dragPreviewDurationSeconds.removeAll()
            self.dragPreviewSourceInSeconds.removeAll()
            needsDisplay = true
        }

        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragging.mouseDownPoint.x
        let deltaSeconds = Double(dx / pxPerSecond)

        switch dragging.mode {
        case .move:
            let proposed = max(0, dragging.originalStartSeconds + deltaSeconds)
            let snapped = snapStartSeconds(
                proposed,
                trackId: dragging.trackId,
                movingClipId: dragging.clipId
            )

            if abs(snapped - dragging.originalStartSeconds) < 1e-9 {
                return
            }
            onMoveClipCommitted?(dragging.clipId, snapped)

        case .trimLeft:
            let originalStart = dragging.originalStartSeconds
            let originalSourceIn = dragging.originalSourceInSeconds
            let originalDuration = dragging.originalDurationSeconds
            let endSeconds = originalStart + originalDuration

            var proposedStart = max(0, originalStart + deltaSeconds)
            proposedStart = min(proposedStart, endSeconds - minClipDurationSeconds)
            let snappedStart = snapStartSeconds(
                proposedStart,
                trackId: dragging.trackId,
                movingClipId: dragging.clipId
            )

            let clampedStart = min(max(0, snappedStart), endSeconds - minClipDurationSeconds)
            let newDuration = max(minClipDurationSeconds, endSeconds - clampedStart)
            let newSourceIn = max(0, originalSourceIn + (clampedStart - originalStart))

            if abs(clampedStart - originalStart) < 1e-9 {
                return
            }
            onTrimClipCommitted?(dragging.clipId, clampedStart, newSourceIn, newDuration)

        case .trimRight:
            let originalStart = dragging.originalStartSeconds
            let originalDuration = dragging.originalDurationSeconds
            let originalEnd = originalStart + originalDuration

            var proposedEnd = (originalEnd + deltaSeconds)
            proposedEnd = max(proposedEnd, originalStart + minClipDurationSeconds)
            let snappedEnd = snapEndSeconds(
                proposedEnd,
                trackId: dragging.trackId,
                trimmingClipId: dragging.clipId
            )

            let clampedEnd = max(snappedEnd, originalStart + minClipDurationSeconds)
            let newDuration = max(minClipDurationSeconds, clampedEnd - originalStart)

            if abs(newDuration - originalDuration) < 1e-9 {
                return
            }
            onTrimClipCommitted?(dragging.clipId, nil, nil, newDuration)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx?.fill(bounds.insetBy(dx: 12, dy: 12))

        for (index, track) in project.timeline.tracks.enumerated() {
            let y = inset + CGFloat(index) * rowHeight

            let label = "\(index)  \(track.kind.rawValue)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            label.draw(at: CGPoint(x: inset, y: y + 2), withAttributes: attrs)

            for clip in track.clips {
                let rect = clipRect(trackIndex: index, clip: clip)

                ctx?.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
                ctx?.fill(rect)

                ctx?.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
                ctx?.stroke(rect, width: 1)

                if clip.id == selectedClipId {
                    ctx?.setStrokeColor(NSColor.selectedControlColor.cgColor)
                    ctx?.stroke(rect.insetBy(dx: -1, dy: -1), width: 2)

                    // 选中态绘制 trim handles（左右边缘）
                    let handleW = handleHitWidthPx
                    let leftHandle = CGRect(x: rect.minX - handleW / 2, y: rect.minY, width: handleW, height: rect.height)
                    let rightHandle = CGRect(x: rect.maxX - handleW / 2, y: rect.minY, width: handleW, height: rect.height)
                    ctx?.setFillColor(NSColor.selectedControlColor.withAlphaComponent(0.5).cgColor)
                    ctx?.fill(leftHandle)
                    ctx?.fill(rightHandle)
                }
            }
        }

        // Playhead
        let phSeconds = scrubPreviewSeconds ?? playheadSeconds
        let x = laneX + CGFloat(max(0, phSeconds)) * pxPerSecond
        if x >= laneX {
            let line = CGRect(x: x, y: inset, width: 1, height: bounds.height - inset * 2)
            ctx?.setFillColor(NSColor.selectedControlColor.withAlphaComponent(0.85).cgColor)
            ctx?.fill(line)
        }

        if project.timeline.tracks.isEmpty {
            let text = "Timeline (placeholder)\nUse + Video Track to add a track."
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            text.draw(in: bounds.insetBy(dx: 24, dy: 24), withAttributes: attrs)
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Arrow keys for frame stepping.
        if event.keyCode == 123 {
            stepFrames(-1)
            return
        }
        if event.keyCode == 124 {
            stepFrames(1)
            return
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else {
            super.keyDown(with: event)
            return
        }

        switch chars {
        case "j":
            // Reverse (if supported); otherwise acts as a "request".
            onSetPlaybackRateRequested?(nextJKLRate(direction: -1))
        case "k":
            onSetPlaybackRateRequested?(0)
        case "l":
            onSetPlaybackRateRequested?(nextJKLRate(direction: 1))
        case ",":
            stepFrames(-1)
        case ".":
            stepFrames(1)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Geometry

    private let inset: CGFloat = 16
    private let rowHeight: CGFloat = 44
    private let clipHeight: CGFloat = 24
    private let clipYOffset: CGFloat = 10
    private let laneX: CGFloat = 120

    // 简化：1 秒 = 80px（后续升级：支持缩放）
    private let pxPerSecond: CGFloat = 80
    private let snapThresholdPx: CGFloat = 8
    private let handleHitWidthPx: CGFloat = 6
    private let minClipDurationSeconds: Double = 0.05

    private func seconds(atX x: CGFloat) -> Double {
        let laneLocal = max(0, x - laneX)
        return Double(laneLocal / pxPerSecond)
    }

    private func stepFrames(_ deltaFrames: Int) {
        let fps = max(1, project.meta.fps)
        let dt = Double(deltaFrames) / fps
        let target = max(0, (scrubPreviewSeconds ?? playheadSeconds) + dt)
        onSetPlaybackRateRequested?(0)
        onSeekRequested?(target)
        scrubPreviewSeconds = target
        needsDisplay = true
    }

    private func nextJKLRate(direction: Int) -> Float {
        // direction: -1 for J, +1 for L
        let maxAbs: Float = 8
        let r = playerRate
        if direction < 0 {
            if r < 0 {
                return max(-maxAbs, r * 2)
            }
            return -1
        } else {
            if r > 0 {
                return min(maxAbs, r * 2)
            }
            return 1
        }
    }

    private func clipRect(trackIndex: Int, clip: Clip) -> CGRect {
        let y = inset + CGFloat(trackIndex) * rowHeight
        let laneWidth: CGFloat = max(0, bounds.width - laneX - inset)
        let startSeconds = dragPreviewStartSeconds[clip.id] ?? clip.timelineStartSeconds
        let x = laneX + CGFloat(startSeconds) * pxPerSecond
        let durationSeconds = dragPreviewDurationSeconds[clip.id] ?? clip.durationSeconds
        let w = max(6, CGFloat(durationSeconds) * pxPerSecond)
        return CGRect(x: x, y: y + clipYOffset, width: min(w, laneWidth), height: clipHeight)
    }

    private func hitTestClip(at point: CGPoint) -> (
        clipId: UUID,
        trackId: UUID,
        startSeconds: Double,
        sourceInSeconds: Double,
        durationSeconds: Double,
        isNearLeftEdge: Bool,
        isNearRightEdge: Bool
    )? {
        for (tIndex, track) in project.timeline.tracks.enumerated() {
            for clip in track.clips {
                let rect = clipRect(trackIndex: tIndex, clip: clip)
                if rect.contains(point) {
                    let isNearLeft = abs(point.x - rect.minX) <= handleHitWidthPx
                    let isNearRight = abs(point.x - rect.maxX) <= handleHitWidthPx
                    return (
                        clip.id,
                        track.id,
                        clip.timelineStartSeconds,
                        clip.sourceInSeconds,
                        clip.durationSeconds,
                        isNearLeft,
                        isNearRight
                    )
                }
            }
        }
        return nil
    }

    private func snapStartSeconds(_ proposed: Double, trackId: UUID, movingClipId: UUID) -> Double {
        let thresholdSeconds = Double(snapThresholdPx / pxPerSecond)

        guard let track = project.timeline.tracks.first(where: { $0.id == trackId }) else {
            return proposed
        }

        // Snap to 0
        var best = proposed
        var bestDist = abs(proposed - 0)
        if bestDist <= thresholdSeconds {
            best = 0
        }

        // Snap to other clips' start/end.
        for clip in track.clips where clip.id != movingClipId {
            let candidates = [
                clip.timelineStartSeconds,
                clip.timelineStartSeconds + clip.durationSeconds
            ]
            for c in candidates {
                let dist = abs(proposed - c)
                if dist < bestDist {
                    bestDist = dist
                    best = c
                }
            }
        }

        if bestDist <= thresholdSeconds {
            return best
        }
        return proposed
    }

    private func snapEndSeconds(_ proposedEnd: Double, trackId: UUID, trimmingClipId: UUID) -> Double {
        let thresholdSeconds = Double(snapThresholdPx / pxPerSecond)

        guard let track = project.timeline.tracks.first(where: { $0.id == trackId }) else {
            return proposedEnd
        }

        var best = proposedEnd
        var bestDist = Double.greatestFiniteMagnitude

        for clip in track.clips where clip.id != trimmingClipId {
            let candidates = [
                clip.timelineStartSeconds,
                clip.timelineStartSeconds + clip.durationSeconds
            ]
            for c in candidates {
                let dist = abs(proposedEnd - c)
                if dist < bestDist {
                    bestDist = dist
                    best = c
                }
            }
        }

        if bestDist <= thresholdSeconds {
            return best
        }
        return proposedEnd
    }
}
