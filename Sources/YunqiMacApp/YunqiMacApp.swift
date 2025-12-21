import EditorCore
import AppKit
import AVFoundation
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

        // Allow system window tab bar behavior.
        NSWindow.allowsAutomaticWindowTabbing = true
    }
}

@main
struct YunqiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.projectWorkspace) private var focusedWorkspace

    @AppStorage(AppPreferences.newProjectOpenTargetKey) private var newProjectTargetRaw: String = OpenTarget.newTab.rawValue
    @AppStorage(AppPreferences.openProjectOpenTargetKey) private var openProjectTargetRaw: String = OpenTarget.newTab.rawValue

    var body: some Scene {
        WindowGroup("Yunqi") {
            ProjectWindowView(launch: nil)
                .frame(minWidth: 980, minHeight: 640)
        }

        WindowGroup(for: ProjectLaunch.self) { launch in
            ProjectWindowView(launch: launch.wrappedValue)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    handleNewProject()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open…") {
                    presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("Save") {
                    _ = focusedWorkspace?.saveOrPromptSaveAs()
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Save As…") {
                    _ = focusedWorkspace?.presentSavePanel()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(after: .newItem) {
                Divider()
                Button("Import Media…") {
                    focusedWorkspace?.presentImportMediaPanel()
                }
                .keyboardShortcut("i", modifiers: [.command])
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    focusedWorkspace?.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])

                Button("Redo") {
                    focusedWorkspace?.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        Settings {
            PreferencesView()
        }
    }

    private var newProjectTarget: OpenTarget {
        OpenTarget(rawValue: newProjectTargetRaw) ?? .newTab
    }

    private var openProjectTarget: OpenTarget {
        OpenTarget(rawValue: openProjectTargetRaw) ?? .newTab
    }

    private func handleNewProject() {
        switch newProjectTarget {
        case .currentTab:
            guard let ws = focusedWorkspace else {
                NSSound.beep()
                return
            }
            guard confirmCloseIfDirty(workspace: ws) else { return }
            ws.newProject()
        case .newTab:
            let requestId = TabAttachManager.shared.requestAttachToKeyWindow()
            openWindow(value: ProjectLaunch.newProject(tabRequestId: requestId))
        case .newWindow:
            openWindow(value: ProjectLaunch.newProject(tabRequestId: nil))
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []

        if panel.runModal() == .OK, let url = panel.url {
            handleOpenProject(url: url)
        }
    }

    private func handleOpenProject(url: URL) {
        switch openProjectTarget {
        case .currentTab:
            guard let ws = focusedWorkspace else {
                NSSound.beep()
                return
            }
            guard confirmCloseIfDirty(workspace: ws) else { return }
            do {
                try ws.openProject(url: url)
            } catch {
                NSLog("Open project failed: \(error)")
                NSSound.beep()
            }
        case .newTab:
            let requestId = TabAttachManager.shared.requestAttachToKeyWindow()
            openWindow(value: ProjectLaunch.openProject(url, tabRequestId: requestId))
        case .newWindow:
            openWindow(value: ProjectLaunch.openProject(url, tabRequestId: nil))
        }
    }

    private func confirmCloseIfDirty(workspace: ProjectWorkspace) -> Bool {
        if !workspace.isDirty { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes made to \"\(workspace.windowTitle)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            return workspace.saveOrPromptSaveAs()
        }
        if resp == .alertSecondButtonReturn {
            return true
        }
        return false
    }
}

private enum ProjectLaunch: Hashable, Codable {
    case newProject(tabRequestId: UUID?)
    case openProject(URL, tabRequestId: UUID?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
        case tabRequestId
    }

    private enum Kind: String, Codable {
        case newProject
        case openProject
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .newProject:
            let tabRequestId = try c.decodeIfPresent(UUID.self, forKey: .tabRequestId)
            self = .newProject(tabRequestId: tabRequestId)
        case .openProject:
            let url = try c.decode(URL.self, forKey: .url)
            let tabRequestId = try c.decodeIfPresent(UUID.self, forKey: .tabRequestId)
            self = .openProject(url, tabRequestId: tabRequestId)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .newProject(tabRequestId):
            try c.encode(Kind.newProject, forKey: .kind)
            try c.encodeIfPresent(tabRequestId, forKey: .tabRequestId)
        case let .openProject(url, tabRequestId):
            try c.encode(Kind.openProject, forKey: .kind)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(tabRequestId, forKey: .tabRequestId)
        }
    }
}

private struct ProjectWindowView: View {
    @StateObject private var workspace = ProjectWorkspace()

    let launch: ProjectLaunch?
    @State private var didApplyLaunch: Bool = false

    var body: some View {
        let tabRequestId: UUID? = {
            guard let launch else { return nil }
            switch launch {
            case let .newProject(tabRequestId):
                return tabRequestId
            case let .openProject(_, tabRequestId):
                return tabRequestId
            }
        }()

        ContentView(workspace: workspace, store: workspace.store)
            .focusedValue(\.projectWorkspace, workspace)
            .background(WindowHooksView(workspace: workspace, tabRequestId: tabRequestId))
            .task {
                guard !didApplyLaunch else { return }
                didApplyLaunch = true

                guard let launch else { return }
                switch launch {
                case .newProject:
                    workspace.newProject()
                case let .openProject(url, _):
                    do {
                        try workspace.openProject(url: url)
                    } catch {
                        NSLog("Open project failed: \(error)")
                        NSSound.beep()
                    }
                }
            }
    }
}

private struct ContentView: View {
    @ObservedObject var workspace: ProjectWorkspace
    @ObservedObject var store: EditorSessionStore

    var body: some View {
        HSplitView {
            SidebarView(workspace: workspace, store: store)
                // `HSplitView` can override child sizing; lock min/ideal/max to prevent collapsing.
                .frame(minWidth: 260, idealWidth: 260, maxWidth: 260)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(100)

            VSplitView {
                PreviewView(workspace: workspace)
                    .frame(minHeight: 260)
                    .layoutPriority(1)

                TimelineHostView(workspace: workspace, store: store)
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
                let isPlaying = workspace.preview.currentRequestedRate != 0
                Button(isPlaying ? "Pause" : "Play") {
                    if isPlaying {
                        workspace.pausePreview()
                    } else {
                        workspace.playPreview()
                    }
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

private struct WindowHooksView: NSViewRepresentable {
    let workspace: ProjectWorkspace
    let tabRequestId: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObserverView()
        view.onWindowChanged = { window in
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.workspace = workspace
        context.coordinator.tabRequestId = tabRequestId
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var workspace: ProjectWorkspace
        var tabRequestId: UUID?
        private weak var window: NSWindow?

        init(workspace: ProjectWorkspace) {
            self.workspace = workspace
            self.tabRequestId = nil
        }

        func attach(to window: NSWindow) {
            if self.window !== window {
                self.window = window
                window.delegate = self
            }
            window.title = workspace.windowTitle

            if let tabRequestId {
                TabAttachManager.shared.completeAttachIfNeeded(requestId: tabRequestId, newWindow: window)
                self.tabRequestId = nil
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if !workspace.isDirty { return true }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Do you want to save the changes made to \"\(workspace.windowTitle)\"?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")

            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                return workspace.saveOrPromptSaveAs()
            }
            if resp == .alertSecondButtonReturn {
                return true
            }
            return false
        }
    }

    private final class WindowObserverView: NSView {
        var onWindowChanged: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindowChanged?(window)
            }
        }
    }
}

private enum OpenTarget: String, CaseIterable, Identifiable {
    case currentTab
    case newTab
    case newWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentTab: return "当前标签"
        case .newTab: return "新标签"
        case .newWindow: return "新窗口(新页面)"
        }
    }
}

private enum AppPreferences {
    static let newProjectOpenTargetKey = "pref.newProject.openTarget"
    static let openProjectOpenTargetKey = "pref.openProject.openTarget"
}

private struct PreferencesView: View {
    @AppStorage(AppPreferences.newProjectOpenTargetKey) private var newProjectTargetRaw: String = OpenTarget.newTab.rawValue
    @AppStorage(AppPreferences.openProjectOpenTargetKey) private var openProjectTargetRaw: String = OpenTarget.newTab.rawValue

    var body: some View {
        Form {
            Picker("New Project 打开方式", selection: $newProjectTargetRaw) {
                ForEach(OpenTarget.allCases) { t in
                    Text(t.title).tag(t.rawValue)
                }
            }

            Picker("Open… 打开方式", selection: $openProjectTargetRaw) {
                ForEach(OpenTarget.allCases) { t in
                    Text(t.title).tag(t.rawValue)
                }
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

@MainActor
private final class TabAttachManager {
    static let shared = TabAttachManager()

    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow?) { self.value = value }
    }

    private var pending: [UUID: WeakWindow] = [:]

    func requestAttachToKeyWindow() -> UUID {
        let id = UUID()
        pending[id] = WeakWindow(NSApp.keyWindow)
        return id
    }

    func completeAttachIfNeeded(requestId: UUID, newWindow: NSWindow) {
        guard let host = pending[requestId]?.value else {
            pending[requestId] = nil
            return
        }
        pending[requestId] = nil

        guard host !== newWindow else { return }

        // Encourage tabbing and then attach.
        host.tabbingMode = .preferred
        newWindow.tabbingMode = .preferred
        host.addTabbedWindow(newWindow, ordered: .above)
    }
}

private struct ProjectWorkspaceFocusedKey: FocusedValueKey {
    typealias Value = ProjectWorkspace
}

private extension FocusedValues {
    var projectWorkspace: ProjectWorkspace? {
        get { self[ProjectWorkspaceFocusedKey.self] }
        set { self[ProjectWorkspaceFocusedKey.self] = newValue }
    }
}

private struct SidebarView: View {
    @ObservedObject var workspace: ProjectWorkspace
    @ObservedObject var store: EditorSessionStore

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
    @ObservedObject var workspace: ProjectWorkspace

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
    @ObservedObject var workspace: ProjectWorkspace
    @ObservedObject var store: EditorSessionStore

    var body: some View {
        TimelineRepresentable(
            project: store.project,
            playheadSeconds: workspace.previewTimeSeconds,
            playerRate: workspace.preview.currentRequestedRate,
            onMoveClipCommitted: { clipId, newStartSeconds in
                Task {
                    do {
                        try await store.moveClip(clipId: clipId, toStartSeconds: newStartSeconds)
                    } catch {
                        NSSound.beep()
                    }
                }
            },
            onMoveClipsCommitted: { moves in
                Task {
                    do {
                        try await store.moveClips(moves)
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
            },
            onSplitClipRequested: { clipId, timeSeconds in
                Task {
                    do {
                        try await store.splitClip(clipId: clipId, at: timeSeconds)
                    } catch {
                        NSSound.beep()
                    }
                }
            },
            onDeleteClipRequested: { clipId in
                Task {
                    do {
                        try await store.deleteClip(clipId: clipId)
                    } catch {
                        NSSound.beep()
                    }
                }
            },
            onDeleteClipsRequested: { clipIds in
                Task {
                    do {
                        try await store.deleteClips(clipIds: clipIds)
                    } catch {
                        NSSound.beep()
                    }
                }
            },
            onRippleDeleteClipsRequested: { clipIds in
                Task {
                    do {
                        try await store.rippleDeleteClips(clipIds: clipIds)
                    } catch {
                        NSSound.beep()
                    }
                }
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
    let onMoveClipsCommitted: ([(clipId: UUID, startSeconds: Double)]) -> Void
    let onTrimClipCommitted: (UUID, Double?, Double?, Double?) -> Void
    let onScrubBegan: () -> Void
    let onScrubEnded: () -> Void
    let onSeekRequested: (Double) -> Void
    let onSetPlaybackRateRequested: (Float) -> Void
    let onSplitClipRequested: (UUID, Double) -> Void
    let onDeleteClipRequested: (UUID) -> Void
    let onDeleteClipsRequested: ([UUID]) -> Void
    let onRippleDeleteClipsRequested: ([UUID]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let timelineView = TimelineNSView()
        timelineView.onMoveClipCommitted = onMoveClipCommitted
        timelineView.onMoveClipsCommitted = onMoveClipsCommitted
        timelineView.onTrimClipCommitted = onTrimClipCommitted
        timelineView.onScrubBegan = onScrubBegan
        timelineView.onScrubEnded = onScrubEnded
        timelineView.onSeekRequested = onSeekRequested
        timelineView.onSetPlaybackRateRequested = onSetPlaybackRateRequested
        timelineView.onSplitClipRequested = onSplitClipRequested
        timelineView.onDeleteClipRequested = onDeleteClipRequested
        timelineView.onDeleteClipsRequested = onDeleteClipsRequested
        timelineView.onRippleDeleteClipsRequested = onRippleDeleteClipsRequested

        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = timelineView

        context.coordinator.timelineView = timelineView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let timelineView = (context.coordinator.timelineView ?? nsView.documentView as? TimelineNSView) else {
            return
        }

        timelineView.project = project
        timelineView.playheadSeconds = playheadSeconds
        timelineView.playerRate = playerRate
        timelineView.onMoveClipCommitted = onMoveClipCommitted
        timelineView.onMoveClipsCommitted = onMoveClipsCommitted
        timelineView.onTrimClipCommitted = onTrimClipCommitted
        timelineView.onScrubBegan = onScrubBegan
        timelineView.onScrubEnded = onScrubEnded
        timelineView.onSeekRequested = onSeekRequested
        timelineView.onSetPlaybackRateRequested = onSetPlaybackRateRequested
        timelineView.onSplitClipRequested = onSplitClipRequested
        timelineView.onDeleteClipRequested = onDeleteClipRequested
        timelineView.onDeleteClipsRequested = onDeleteClipsRequested
        timelineView.onRippleDeleteClipsRequested = onRippleDeleteClipsRequested

        // Expand the document view to fit the timeline content so the user can scroll.
        let visibleWidth = nsView.contentView.bounds.width
        let visibleHeight = nsView.contentView.bounds.height
        let contentSize = timelineView.contentSize(minVisibleWidth: visibleWidth, minVisibleHeight: visibleHeight)
        if timelineView.frame.size != contentSize {
            timelineView.frame = CGRect(origin: .zero, size: contentSize)
        }

        timelineView.needsDisplay = true
    }

    final class Coordinator {
        var timelineView: TimelineNSView?
    }
}

private final class TimelineNSView: NSView {
    var project: Project = Project(meta: ProjectMeta(name: "Yunqi")) {
        didSet {
            window?.invalidateCursorRects(for: self)
            pruneMiniCaches()
        }
    }
    var playheadSeconds: Double = 0
    var playerRate: Float = 0
    var onMoveClipCommitted: ((UUID, Double) -> Void)?
    var onMoveClipsCommitted: (([(clipId: UUID, startSeconds: Double)]) -> Void)?
    var onTrimClipCommitted: ((UUID, Double?, Double?, Double?) -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?
    var onSeekRequested: ((Double) -> Void)?
    var onSetPlaybackRateRequested: ((Float) -> Void)?
    var onSplitClipRequested: ((UUID, Double) -> Void)?
    var onDeleteClipRequested: ((UUID) -> Void)?
    var onDeleteClipsRequested: (([UUID]) -> Void)?
    var onRippleDeleteClipsRequested: (([UUID]) -> Void)?

    private var selectedClipIds: Set<UUID> = []
    private var primarySelectedClipId: UUID?
    private var dragging: DragState?
    private var scrubbing: ScrubState?
    private var scrubPreviewSeconds: Double?
    private var marquee: MarqueeState?
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
        let selectedOriginalStarts: [UUID: Double]
        let originalSourceInSeconds: Double
        let originalDurationSeconds: Double
        let mouseDownPoint: CGPoint
    }

    private struct MarqueeState {
        let startPoint: CGPoint
        var currentPoint: CGPoint
        let additive: Bool
        let baseSelection: Set<UUID>
        var isActive: Bool { abs(currentPoint.x - startPoint.x) > 2 || abs(currentPoint.y - startPoint.y) > 2 }
    }

    private struct ScrubState {
        let mouseDownPoint: CGPoint
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let isShift = event.modifierFlags.contains(.shift)

        // Double-click on ruler resets zoom.
        if event.clickCount == 2, isPointInTimeRuler(point) {
            resetZoom(anchorPoint: point)
            needsDisplay = true
            return
        }

        if let hit = hitTestClip(at: point) {
            if isShift {
                if selectedClipIds.contains(hit.clipId) {
                    selectedClipIds.remove(hit.clipId)
                    if primarySelectedClipId == hit.clipId {
                        primarySelectedClipId = selectedClipIds.first
                    }
                } else {
                    selectedClipIds.insert(hit.clipId)
                    primarySelectedClipId = hit.clipId
                }
            } else {
                selectedClipIds = [hit.clipId]
                primarySelectedClipId = hit.clipId
            }

            let mode: DragMode
            if hit.isNearLeftEdge {
                mode = .trimLeft
            } else if hit.isNearRightEdge {
                mode = .trimRight
            } else {
                mode = .move
            }

            // Prepare group move if the clicked clip is in current selection.
            var selectedStarts: [UUID: Double] = [:]
            if mode == .move, selectedClipIds.contains(hit.clipId), selectedClipIds.count > 1 {
                selectedStarts.reserveCapacity(selectedClipIds.count)
                for id in selectedClipIds {
                    if let info = locateClip(id: id) {
                        selectedStarts[id] = info.startSeconds
                    }
                }
            }

            dragging = DragState(
                clipId: hit.clipId,
                trackId: hit.trackId,
                mode: mode,
                originalStartSeconds: hit.startSeconds,
                selectedOriginalStarts: selectedStarts,
                originalSourceInSeconds: hit.sourceInSeconds,
                originalDurationSeconds: hit.durationSeconds,
                mouseDownPoint: point
            )
            scrubbing = nil
            scrubPreviewSeconds = nil
            marquee = nil
        } else {
            // Double-click empty space: bring playhead into view.
            if event.clickCount == 2, point.x >= laneX {
                scrollToTime(playheadSeconds, centered: true)
                needsDisplay = true
                return
            }

            if !isShift {
                selectedClipIds.removeAll()
                primarySelectedClipId = nil
            }
            dragging = nil
            dragPreviewStartSeconds.removeAll()
            dragPreviewDurationSeconds.removeAll()
            dragPreviewSourceInSeconds.removeAll()

            // 空白区域：优先支持框选；靠近播放头时拖拽视作 scrub。
            if point.x >= laneX {
                let phX = laneX + CGFloat(max(0, playheadSeconds)) * pxPerSecond
                if abs(point.x - phX) <= 4 {
                    onScrubBegan?()
                    scrubbing = ScrubState(mouseDownPoint: point)
                    let s = seconds(atX: point.x)
                    scrubPreviewSeconds = s
                    onSeekRequested?(s)
                    marquee = nil
                } else {
                    scrubbing = nil
                    scrubPreviewSeconds = nil
                    marquee = MarqueeState(
                        startPoint: point,
                        currentPoint: point,
                        additive: isShift,
                        baseSelection: selectedClipIds
                    )
                }
            } else {
                scrubbing = nil
                scrubPreviewSeconds = nil
                marquee = nil
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

        if var marquee {
            let point = convert(event.locationInWindow, from: nil)
            marquee.currentPoint = point
            self.marquee = marquee

            if marquee.isActive {
                let rect = selectionRect(from: marquee.startPoint, to: marquee.currentPoint)
                let hits = clipIdsIntersecting(rect: rect)
                if marquee.additive {
                    selectedClipIds = marquee.baseSelection.union(hits)
                } else {
                    selectedClipIds = hits
                }
                primarySelectedClipId = selectedClipIds.first
            }
            needsDisplay = true
            return
        }

        guard let dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragging.mouseDownPoint.x
        let deltaSeconds = Double(dx / pxPerSecond)

        switch dragging.mode {
        case .move:
            if !dragging.selectedOriginalStarts.isEmpty {
                for (id, start) in dragging.selectedOriginalStarts {
                    let proposed = start + deltaSeconds
                    dragPreviewStartSeconds[id] = max(0, proposed)
                }
            } else {
                let proposed = dragging.originalStartSeconds + deltaSeconds
                dragPreviewStartSeconds[dragging.clipId] = max(0, proposed)
            }

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

        if let marquee {
            // Click without drag: set playhead.
            if !marquee.isActive, marquee.startPoint.x >= laneX {
                let s = seconds(atX: marquee.startPoint.x)
                onSeekRequested?(s)
            }
            self.marquee = nil
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

            if !dragging.selectedOriginalStarts.isEmpty {
                let delta = snapped - dragging.originalStartSeconds
                var moves: [(clipId: UUID, startSeconds: Double)] = []
                moves.reserveCapacity(dragging.selectedOriginalStarts.count)
                for (id, start) in dragging.selectedOriginalStarts {
                    moves.append((id, max(0, start + delta)))
                }
                onMoveClipsCommitted?(moves)
            } else {
                onMoveClipCommitted?(dragging.clipId, snapped)
            }

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

        drawTimeRuler(in: dirtyRect)

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

                // Mini thumbnails / waveforms.
                switch track.kind {
                case .video:
                    drawVideoThumbnails(in: rect, clip: clip)
                case .audio:
                    drawAudioWaveform(in: rect, clip: clip)
                default:
                    break
                }

                ctx?.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
                ctx?.stroke(rect, width: 1)

                if selectedClipIds.contains(clip.id) {
                    ctx?.setStrokeColor(NSColor.selectedControlColor.cgColor)
                    ctx?.stroke(rect.insetBy(dx: -1, dy: -1), width: 2)

                    if clip.id == primarySelectedClipId {
                        // 主选中态绘制 trim handles（左右边缘）
                        let handleW = handleHitWidthPx
                        let leftHandle = CGRect(x: rect.minX - handleW / 2, y: rect.minY, width: handleW, height: rect.height)
                        let rightHandle = CGRect(x: rect.maxX - handleW / 2, y: rect.minY, width: handleW, height: rect.height)
                        ctx?.setFillColor(NSColor.selectedControlColor.withAlphaComponent(0.5).cgColor)
                        ctx?.fill(leftHandle)
                        ctx?.fill(rightHandle)
                    }
                }
            }
        }

        // Marquee selection rect
        if let marquee, marquee.isActive {
            let rect = selectionRect(from: marquee.startPoint, to: marquee.currentPoint)
            ctx?.setFillColor(NSColor.selectedControlColor.withAlphaComponent(0.12).cgColor)
            ctx?.fill(rect)
            ctx?.setStrokeColor(NSColor.selectedControlColor.withAlphaComponent(0.6).cgColor)
            ctx?.stroke(rect, width: 1)
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

    override func resetCursorRects() {
        super.resetCursorRects()

        // Show a left-right resize cursor near clip edges to hint trim.
        for (index, track) in project.timeline.tracks.enumerated() {
            for clip in track.clips {
                let rect = clipRect(trackIndex: index, clip: clip)
                let handleW = handleHitWidthPx
                let leftHandle = CGRect(x: rect.minX - handleW / 2, y: rect.minY, width: handleW, height: rect.height)
                let rightHandle = CGRect(x: rect.maxX - handleW / 2, y: rect.minY, width: handleW, height: rect.height)
                addCursorRect(leftHandle, cursor: .resizeLeftRight)
                addCursorRect(rightHandle, cursor: .resizeLeftRight)
            }
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Cmd +/- zoom
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars.count == 1,
           let scrollView = enclosingScrollView
        {
            let key = chars
            if key == "+" || key == "=" {
                zoomBy(step: 1.1, scrollView: scrollView)
                return
            }
            if key == "-" {
                zoomBy(step: 1.0 / 1.1, scrollView: scrollView)
                return
            }
        }

        // Delete / Ripple Delete
        // Default Delete: ripple delete (NLE-style).
        // Shift+Delete: plain delete (leave gap).
        if event.keyCode == 51 || event.keyCode == 117 {
            if event.modifierFlags.contains(.shift) {
                if let primary = primarySelectedClipId, selectedClipIds.count <= 1 {
                    onDeleteClipRequested?(primary)
                    return
                }
                if !selectedClipIds.isEmpty {
                    onDeleteClipsRequested?(Array(selectedClipIds))
                    return
                }
            } else {
                if !selectedClipIds.isEmpty {
                    onRippleDeleteClipsRequested?(Array(selectedClipIds))
                    return
                }
                if let primary = primarySelectedClipId {
                    onRippleDeleteClipsRequested?([primary])
                    return
                }
            }
        }

        // Home/End: jump playhead to start/end of timeline.
        if event.keyCode == 115 {
            let target = 0.0
            onSetPlaybackRateRequested?(0)
            onSeekRequested?(target)
            scrollToTime(target, centered: true)
            needsDisplay = true
            return
        }
        if event.keyCode == 119 {
            let target = timelineEndSeconds()
            onSetPlaybackRateRequested?(0)
            onSeekRequested?(target)
            scrollToTime(target, centered: true)
            needsDisplay = true
            return
        }

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
        case " ":
            // Space: toggle play/pause like NLEs (Final Cut etc.).
            onSetPlaybackRateRequested?(playerRate == 0 ? 1 : 0)
            return
        case "b", "s":
            // Split (razor): prefer Cmd+B behavior but also allow plain B/S when timeline has focus.
            if let id = primarySelectedClipId {
                let t = playheadSeconds
                onSplitClipRequested?(id, t)
                return
            }
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

    // MARK: - Zoom (Cmd + scroll)

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            handleZoom(with: event)
            return
        }

        // Shift + wheel: horizontal scroll (timeline-style).
        if event.modifierFlags.contains(.shift), let scrollView = enclosingScrollView {
            let clipView = scrollView.contentView
            let vertical = event.scrollingDeltaY
            let horizontal = event.scrollingDeltaX

            // Prefer natural horizontal delta if present; otherwise map vertical to horizontal.
            let dx = abs(horizontal) > 0.01 ? horizontal : vertical
            if abs(dx) > 0.01 {
                var origin = clipView.bounds.origin
                origin.x = max(0, min(origin.x - dx, max(0, frame.width - clipView.bounds.width)))
                clipView.setBoundsOrigin(origin)
                scrollView.reflectScrolledClipView(clipView)
                return
            }
        }
        super.scrollWheel(with: event)
    }

    private func handleZoom(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else { return }

        let location = convert(event.locationInWindow, from: nil)
        let deltaY = event.scrollingDeltaY
        if abs(deltaY) < 0.01 { return }

        // Map wheel delta to a gentle zoom factor.
        let step: CGFloat = 1.1
        let factor: CGFloat = (deltaY < 0) ? step : (1.0 / step)
        applyZoom(factor: factor, anchorPoint: location, scrollView: scrollView)
    }

    private func zoomBy(step factor: CGFloat, scrollView: NSScrollView) {
        let clipView = scrollView.contentView
        // Anchor at center of visible region.
        let visibleCenterX = clipView.bounds.midX
        let anchorPoint = CGPoint(x: visibleCenterX, y: clipView.bounds.midY)
        applyZoom(factor: factor, anchorPoint: anchorPoint, scrollView: scrollView)
    }

    private func resetZoom(anchorPoint: CGPoint) {
        guard let scrollView = enclosingScrollView else {
            pxPerSecond = defaultPxPerSecond
            return
        }
        let clipView = scrollView.contentView
        let oldOriginX = clipView.bounds.origin.x
        let visibleX = anchorPoint.x - oldOriginX
        let t = seconds(atX: anchorPoint.x)

        pxPerSecond = defaultPxPerSecond
        resizeToFit(scrollView: scrollView)

        let newContentX = laneX + CGFloat(max(0, t)) * pxPerSecond
        let newOriginX = max(0, newContentX - visibleX)
        clipView.setBoundsOrigin(NSPoint(x: newOriginX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func applyZoom(factor: CGFloat, anchorPoint: CGPoint, scrollView: NSScrollView) {
        let clipView = scrollView.contentView
        let oldPx = pxPerSecond
        let oldOriginX = clipView.bounds.origin.x
        let visibleX = anchorPoint.x - oldOriginX
        let t = seconds(atX: anchorPoint.x)

        var newPx = oldPx * factor
        newPx = min(maxPxPerSecond, max(minPxPerSecond, newPx))
        if abs(newPx - oldPx) < 0.001 { return }

        pxPerSecond = newPx
        resizeToFit(scrollView: scrollView)

        let newContentX = laneX + CGFloat(max(0, t)) * pxPerSecond
        let newOriginX = max(0, newContentX - visibleX)
        clipView.setBoundsOrigin(NSPoint(x: newOriginX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)

        needsDisplay = true
    }

    private func resizeToFit(scrollView: NSScrollView) {
        let clipView = scrollView.contentView
        let newSize = contentSize(minVisibleWidth: clipView.bounds.width, minVisibleHeight: clipView.bounds.height)
        if frame.size != newSize {
            frame = CGRect(origin: .zero, size: newSize)
        }
    }

    // MARK: - Selection helpers

    private func selectionRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func clipIdsIntersecting(rect: CGRect) -> Set<UUID> {
        var out: Set<UUID> = []
        for (index, track) in project.timeline.tracks.enumerated() {
            for clip in track.clips {
                if clipRect(trackIndex: index, clip: clip).intersects(rect) {
                    out.insert(clip.id)
                }
            }
        }
        return out
    }

    private func locateClip(id: UUID) -> (trackId: UUID, startSeconds: Double)? {
        for track in project.timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return (track.id, clip.timelineStartSeconds)
            }
        }
        return nil
    }

    // MARK: - Geometry

    private let inset: CGFloat = 16
    private let rowHeight: CGFloat = 44
    private let clipHeight: CGFloat = 24
    private let clipYOffset: CGFloat = 10
    private let laneX: CGFloat = 120

    // 简化：默认 1 秒 = 80px；支持 Cmd+滚轮缩放。
    private let defaultPxPerSecond: CGFloat = 80
    private var pxPerSecond: CGFloat = 80
    private let minPxPerSecond: CGFloat = 20
    private let maxPxPerSecond: CGFloat = 400
    private let snapThresholdPx: CGFloat = 8
    private let handleHitWidthPx: CGFloat = 6
    private let minClipDurationSeconds: Double = 0.05

    // MARK: - Mini thumbnails / waveforms

    private struct ThumbnailStrip {
        var count: Int
        var images: [CGImage]
    }

    private struct Waveform {
        var count: Int
        var samples: [Float]
    }

    private var thumbnailCache: [UUID: ThumbnailStrip] = [:]
    private var waveformCache: [UUID: Waveform] = [:]
    private var thumbnailInFlight: Set<UUID> = []
    private var waveformInFlight: Set<UUID> = []

    private func assetURL(for assetId: UUID) -> URL? {
        guard let record = project.mediaAssets.first(where: { $0.id == assetId }) else { return nil }
        return URL(fileURLWithPath: record.originalPath)
    }

    private func drawVideoThumbnails(in rect: CGRect, clip: Clip) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        if !rect.intersects(visible) { return }

        let desired = desiredThumbnailCount(for: rect)
        if let cached = thumbnailCache[clip.id], cached.count >= desired, !cached.images.isEmpty {
            ctx.saveGState()
            ctx.addRect(rect)
            ctx.clip()

            ctx.setAlpha(0.55)

            let images = cached.images
            if let first = images.first {
                let iw = CGFloat(first.width)
                let ih = CGFloat(first.height)
                if iw > 1, ih > 1 {
                    let aspect = iw / ih
                    let drawH = rect.height
                    let drawW = max(10, drawH * aspect)
                    var x = rect.minX
                    var i = 0
                    while x < rect.maxX {
                        let dest = CGRect(x: x, y: rect.minY, width: drawW, height: drawH)
                        let img = images[min(i, images.count - 1)]
                        drawCGImage(img, in: dest, on: ctx)
                        x += drawW
                        i += 1
                    }
                }
            }

            ctx.restoreGState()
            return
        }

        ensureThumbnailStrip(for: clip, desiredCount: desired)
    }

    private func drawCGImage(_ image: CGImage, in rect: CGRect, on ctx: CGContext) {
        // In a flipped NSView, drawing CGImages directly can appear upside-down.
        // Apply a vertical flip in the destination rect so thumbnails match expected orientation.
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        ctx.draw(image, in: local)
        ctx.restoreGState()
    }

    private func drawAudioWaveform(in rect: CGRect, clip: Clip) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        if !rect.intersects(visible) { return }

        let desired = desiredWaveformCount(for: rect)
        if let cached = waveformCache[clip.id], cached.count >= desired, !cached.samples.isEmpty {
            ctx.saveGState()
            ctx.addRect(rect)
            ctx.clip()

            let midY = rect.midY
            let ampScale = rect.height * 0.40
            ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(1)

            let samples = cached.samples
            let n = samples.count
            if n == 1 {
                let a = CGFloat(samples[0])
                ctx.move(to: CGPoint(x: rect.midX, y: midY - a * ampScale))
                ctx.addLine(to: CGPoint(x: rect.midX, y: midY + a * ampScale))
                ctx.strokePath()
            } else {
                for i in 0..<n {
                    let t = CGFloat(i) / CGFloat(n - 1)
                    let x = rect.minX + t * rect.width
                    let a = CGFloat(samples[i])
                    ctx.move(to: CGPoint(x: x, y: midY - a * ampScale))
                    ctx.addLine(to: CGPoint(x: x, y: midY + a * ampScale))
                }
                ctx.strokePath()
            }

            ctx.restoreGState()
            return
        }

        ensureWaveform(for: clip, desiredCount: desired)
    }

    private func ensureThumbnailStrip(for clip: Clip, desiredCount: Int) {
        if let cached = thumbnailCache[clip.id], cached.count >= desiredCount, !cached.images.isEmpty { return }
        if thumbnailInFlight.contains(clip.id) { return }
        guard let url = assetURL(for: clip.assetId) else { return }

        thumbnailInFlight.insert(clip.id)

        let clipId = clip.id
        let sourceIn = max(0, clip.sourceInSeconds)
        let sourceDuration = max(0.05, clip.durationSeconds * max(0.0001, clip.speed))
        let n = max(1, min(12, desiredCount))
        let times: [Double] = (0..<n).map { i in
            let u = (Double(i) + 0.5) / Double(n)
            return sourceIn + u * sourceDuration
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var images: [CGImage] = []
            images.reserveCapacity(times.count)
            for t in times {
                if let image = await self.generateThumbnail(url: url, timeSeconds: t) {
                    images.append(image)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.thumbnailInFlight.remove(clipId)
                if !images.isEmpty {
                    self.thumbnailCache[clipId] = ThumbnailStrip(count: desiredCount, images: images)
                    self.needsDisplay = true
                }
            }
        }
    }

    private func ensureWaveform(for clip: Clip, desiredCount: Int) {
        if let cached = waveformCache[clip.id], cached.count >= desiredCount, !cached.samples.isEmpty { return }
        if waveformInFlight.contains(clip.id) { return }
        guard let url = assetURL(for: clip.assetId) else { return }

        waveformInFlight.insert(clip.id)
        let clipId = clip.id
        let start = max(0, clip.sourceInSeconds)
        let duration = max(0.05, clip.durationSeconds * max(0.0001, clip.speed))

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let samples = await self.generateWaveform(url: url, startSeconds: start, durationSeconds: duration, desiredCount: desiredCount)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.waveformInFlight.remove(clipId)
                if let samples {
                    self.waveformCache[clipId] = Waveform(count: desiredCount, samples: samples)
                    self.needsDisplay = true
                }
            }
        }
    }

    private func desiredThumbnailCount(for rect: CGRect) -> Int {
        // Approx: one sample per ~120px, clamped.
        return max(1, min(12, Int(ceil(rect.width / 120))))
    }

    private func desiredWaveformCount(for rect: CGRect) -> Int {
        // Approx: one bar per ~6px, clamped.
        return max(24, min(256, Int((rect.width / 6).rounded())))
    }

    private func generateThumbnail(url: URL, timeSeconds: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let time = CMTime(seconds: max(0, timeSeconds), preferredTimescale: 600)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 180, height: 120)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        do {
            var actual = CMTime.zero
            return try gen.copyCGImage(at: time, actualTime: &actual)
        } catch {
            return nil
        }
    }

    private func generateWaveform(
        url: URL,
        startSeconds: Double,
        durationSeconds: Double,
        desiredCount: Int
    ) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { return nil }

            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            reader.add(output)

            let start = CMTime(seconds: max(0, startSeconds), preferredTimescale: 600)
            let dur = CMTime(seconds: max(0.05, durationSeconds), preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: dur)

            guard reader.startReading() else { return nil }

            var rmsValues: [Float] = []
            rmsValues.reserveCapacity(512)

            while reader.status == .reading {
                guard let sb = output.copyNextSampleBuffer() else { break }
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }

                var totalLength: Int = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPointer
                )
                if status != kCMBlockBufferNoErr { continue }
                guard let dataPointer, totalLength >= 2 else { continue }

                let sampleCount = totalLength / MemoryLayout<Int16>.size
                if sampleCount <= 0 { continue }

                let ptr = dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { $0 }
                var peak: Double = 0
                for i in 0..<sampleCount {
                    let v = abs(Double(ptr[i]) / Double(Int16.max))
                    if v > peak { peak = v }
                }
                rmsValues.append(Float(peak))
            }

            if rmsValues.isEmpty { return nil }

            let maxVal = rmsValues.max() ?? 1
            let normalized = maxVal > 0 ? rmsValues.map { $0 / maxVal } : rmsValues
            return resample(values: normalized, to: max(16, min(256, desiredCount)))
        } catch {
            return nil
        }
    }

    private func pruneMiniCaches() {
        var live: Set<UUID> = []
        for track in project.timeline.tracks {
            for clip in track.clips {
                live.insert(clip.id)
            }
        }

        thumbnailCache = thumbnailCache.filter { live.contains($0.key) }
        waveformCache = waveformCache.filter { live.contains($0.key) }
        thumbnailInFlight = thumbnailInFlight.filter { live.contains($0) }
        waveformInFlight = waveformInFlight.filter { live.contains($0) }
    }

    private func resample(values: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !values.isEmpty else { return Array(repeating: 0, count: count) }
        if values.count == 1 { return Array(repeating: values[0], count: count) }
        if values.count == count { return values }

        var out: [Float] = []
        out.reserveCapacity(count)

        let n = values.count
        for i in 0..<count {
            let t = Float(i) / Float(max(1, count - 1))
            let p = t * Float(n - 1)
            let i0 = Int(p.rounded(.down))
            let i1 = min(n - 1, i0 + 1)
            let frac = p - Float(i0)
            let v = values[i0] * (1 - frac) + values[i1] * frac
            out.append(v)
        }
        return out
    }

    // MARK: - Navigation helpers

    private func timelineEndSeconds() -> Double {
        var maxEnd: Double = 0
        for track in project.timeline.tracks {
            for clip in track.clips {
                maxEnd = max(maxEnd, clip.timelineStartSeconds + clip.durationSeconds)
            }
        }
        return max(0, maxEnd)
    }

    private func scrollToTime(_ seconds: Double, centered: Bool) {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let visibleW = clipView.bounds.width
        let targetX = laneX + CGFloat(max(0, seconds)) * pxPerSecond

        var originX: CGFloat
        if centered {
            originX = targetX - visibleW * 0.5
        } else {
            originX = targetX - 24
        }

        originX = max(0, min(originX, max(0, frame.width - visibleW)))
        clipView.setBoundsOrigin(NSPoint(x: originX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

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
        let startSeconds = dragPreviewStartSeconds[clip.id] ?? clip.timelineStartSeconds
        let x = laneX + CGFloat(startSeconds) * pxPerSecond
        let durationSeconds = dragPreviewDurationSeconds[clip.id] ?? clip.durationSeconds
        let w = max(6, CGFloat(durationSeconds) * pxPerSecond)
        return CGRect(x: x, y: y + clipYOffset, width: w, height: clipHeight)
    }

    func contentSize(minVisibleWidth: CGFloat, minVisibleHeight: CGFloat) -> CGSize {
        let tracksCount = max(1, project.timeline.tracks.count)
        let contentHeight = max(minVisibleHeight, inset * 2 + CGFloat(tracksCount) * rowHeight)

        var maxEndSeconds: Double = 0
        for track in project.timeline.tracks {
            for clip in track.clips {
                maxEndSeconds = max(maxEndSeconds, clip.timelineStartSeconds + clip.durationSeconds)
            }
        }
        // Ensure playhead is always reachable even if no clips.
        maxEndSeconds = max(maxEndSeconds, playheadSeconds)

        let rightPadding: CGFloat = 240
        let contentWidth = max(minVisibleWidth, laneX + CGFloat(maxEndSeconds) * pxPerSecond + rightPadding)
        return CGSize(width: contentWidth, height: contentHeight)
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

    // MARK: - Time ruler

    private func drawTimeRuler(in dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Draw ruler only for the visible x-range.
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        let startTime = max(0, seconds(atX: visible.minX))
        let endTime = max(startTime, seconds(atX: visible.maxX))

        let rulerHeight = inset
        let rulerRect = CGRect(x: 0, y: 0, width: bounds.width, height: rulerHeight)

        // Very light background band.
        ctx.saveGState()
        ctx.addRect(rulerRect)
        ctx.clip()

        // Background: keep it very subtle so it doesn't fight clip visuals.
        ctx.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.10).cgColor)
        ctx.fill(rulerRect)

        // Baseline
        let baselineY: CGFloat = rulerRect.maxY - 0.5
        // Baseline: low-contrast separator.
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: laneX, y: baselineY))
        ctx.addLine(to: CGPoint(x: rulerRect.maxX, y: baselineY))
        ctx.strokePath()

        // Choose tick spacing based on current scale (aim for readable labels).
        let desiredMajorPx: CGFloat = 120
        let candidateSeconds: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200]
        var majorSpacing: Double = 5
        for s in candidateSeconds {
            if CGFloat(s) * pxPerSecond >= desiredMajorPx {
                majorSpacing = s
                break
            }
        }
        let minorSpacing = majorSpacing / 5

        let labelY: CGFloat = 2
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.85)
        ]

        func drawTick(at time: Double, isMajor: Bool) {
            let x = laneX + CGFloat(time) * pxPerSecond
            if x < visible.minX - 80 || x > visible.maxX + 80 { return }

            let tickHeight: CGFloat = isMajor ? 9 : 5
            // Ticks: major is readable, minor stays subtle.
            let tickAlpha: CGFloat = isMajor ? 0.55 : 0.25
            ctx.setStrokeColor(NSColor.tertiaryLabelColor.withAlphaComponent(tickAlpha).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: baselineY - tickHeight))
            ctx.addLine(to: CGPoint(x: x, y: baselineY))
            ctx.strokePath()

            if isMajor, CGFloat(majorSpacing) * pxPerSecond >= 80 {
                let label = formatTimeLabel(seconds: time)
                label.draw(at: CGPoint(x: x + 3, y: labelY), withAttributes: labelAttrs)
            }
        }

        // Ticks
        let minorStart = floor(startTime / minorSpacing) * minorSpacing
        var t = minorStart
        while t <= endTime + minorSpacing {
            let isMajor = abs((t / majorSpacing).rounded() - (t / majorSpacing)) < 1e-9
            drawTick(at: t, isMajor: isMajor)
            t += minorSpacing
        }

        // Playhead marker in ruler (small, unobtrusive)
        let phSeconds = scrubPreviewSeconds ?? playheadSeconds
        let phX = laneX + CGFloat(max(0, phSeconds)) * pxPerSecond
        if phX >= laneX, phX <= rulerRect.maxX + 2 {
            // Playhead: slightly muted so it doesn't overpower the ruler.
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.70).cgColor)
            let caret = CGMutablePath()
            caret.move(to: CGPoint(x: phX, y: baselineY))
            caret.addLine(to: CGPoint(x: phX - 4.5, y: baselineY - 7.5))
            caret.addLine(to: CGPoint(x: phX + 4.5, y: baselineY - 7.5))
            caret.closeSubpath()
            ctx.addPath(caret)
            ctx.fillPath()
        }

        ctx.restoreGState()
    }

    private func isPointInTimeRuler(_ point: CGPoint) -> Bool {
        // Ruler occupies the top band above tracks.
        point.y >= 0 && point.y <= inset && point.x >= laneX
    }

    private func formatTimeLabel(seconds: Double) -> String {
        // Guard against floating-point imprecision (e.g. 3.999999 should display as 00:04).
        let epsilon = 1e-6
        let total = max(0, Int((seconds + epsilon).rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
