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

#if DEBUG
        NSLog("[i18n] Locale.preferredLanguages=%@", Locale.preferredLanguages.joined(separator: ", "))
        NSLog("[i18n] Bundle.main.preferredLocalizations=%@", Bundle.main.preferredLocalizations.joined(separator: ", "))
        NSLog("[i18n] Bundle.module.localizations=%@", Bundle.module.localizations.joined(separator: ", "))
        NSLog("[i18n] Bundle.module.preferredLocalizations=%@", Bundle.module.preferredLocalizations.joined(separator: ", "))
        NSLog("[i18n] sample menu.section.clip=%@", L("menu.section.clip"))
#endif

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
        WindowGroup(L("app.name")) {
            ProjectWindowView(launch: nil)
                .frame(minWidth: 980, minHeight: 640)
        }

        WindowGroup(for: ProjectLaunch.self) { launch in
            ProjectWindowView(launch: launch.wrappedValue)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.file.newProject")) {
                    handleNewProject()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button(L("menu.file.open")) {
                    presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                if let ws = focusedWorkspace {
                    FileSaveCommands(workspace: ws)
                } else {
                    Button(L("menu.file.save")) {}
                        .keyboardShortcut("s", modifiers: [.command])
                        .disabled(true)

                    Button(L("menu.file.saveAs")) {}
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(true)
                }
            }

            CommandGroup(after: .newItem) {
                Divider()
                if let ws = focusedWorkspace {
                    FileImportExportCommands(workspace: ws)
                } else {
                    Button(L("menu.file.importMedia")) {}
                        .keyboardShortcut("i", modifiers: [.command])
                        .disabled(true)

                    Button(L("menu.file.export")) {}
                        .keyboardShortcut("e", modifiers: [.command])
                        .disabled(true)
                }
            }

            CommandGroup(replacing: .undoRedo) {
                if let ws = focusedWorkspace {
                    UndoRedoCommands(store: ws.store) {
                        ws.undo()
                    } redo: {
                        ws.redo()
                    }
                } else {
                    Button(L("menu.edit.undo")) {}
                        .keyboardShortcut("z", modifiers: [.command])
                        .disabled(true)

                    Button(L("menu.edit.redo")) {}
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                        .disabled(true)
                }
            }

            CommandMenu(L("menu.section.playback")) {
                if let ws = focusedWorkspace {
                    PlaybackCommands(workspace: ws)
                } else {
                    Button(L("menu.playback.playPause")) {}
                        .keyboardShortcut(.space, modifiers: [])
                        .disabled(true)

                    Button(L("menu.playback.stop")) {}
                        .disabled(true)

                    Divider()

                    Button(L("menu.playback.toggleLoop")) {}
                        .keyboardShortcut("l", modifiers: [.command])
                        .disabled(true)
                }
            }

            CommandMenu(L("menu.section.selection")) {
                Button(L("menu.selection.selectAll")) {
                    NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                }

                Button(L("menu.selection.deselect")) {
                    NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            CommandMenu(L("menu.section.range")) {
                if let ws = focusedWorkspace {
                    RangeCommands(workspace: ws)
                } else {
                    Button(L("menu.range.setIn")) {}
                        .disabled(true)

                    Button(L("menu.range.setOut")) {}
                        .disabled(true)

                    Divider()

                    Button(L("menu.range.clear")) {}
                        .disabled(true)

                    Button(L("menu.range.rippleDeleteRange")) {}
                        .disabled(true)
                }
            }

            CommandMenu(L("menu.section.timeline")) {
                if let ws = focusedWorkspace {
                    TimelineCommands(workspace: ws)
                } else {
                    Button(L("menu.timeline.addVideoTrack")) {}
                        .disabled(true)

                    Button(L("menu.timeline.addAudioTrack")) {}
                        .disabled(true)

                    Divider()

                    Button(L("menu.timeline.collapseAudioComponents")) {}
                        .keyboardShortcut("a", modifiers: [.command, .option])
                        .disabled(true)

                    Divider()

                    Button(L("menu.timeline.toggleTrackMute")) {}
                        .keyboardShortcut("m", modifiers: [.control])
                        .disabled(true)

                    Button(L("menu.timeline.toggleTrackSolo")) {}
                        .keyboardShortcut("s", modifiers: [.control])
                        .disabled(true)
                }
            }

            CommandMenu(L("menu.section.clip")) {
                if let ws = focusedWorkspace {
                    ClipCommands(workspace: ws)
                } else {
                    Button(L("menu.blade")) {}
                        .keyboardShortcut("b", modifiers: [.command])
                        .disabled(true)

                    Button(L("menu.bladeAll")) {}
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                        .disabled(true)

                    Divider()

                    Button(L("menu.increaseClipVolume")) {}
                        .keyboardShortcut("=", modifiers: [.option])
                        .disabled(true)

                    Button(L("menu.decreaseClipVolume")) {}
                        .keyboardShortcut("-", modifiers: [.option])
                        .disabled(true)

                    Divider()

                    Button(L("menu.rippleDelete")) {}
                        .keyboardShortcut(.delete, modifiers: [])
                        .disabled(true)

                    Button(L("menu.delete")) {}
                        .keyboardShortcut(.delete, modifiers: [.shift])
                        .disabled(true)
                }
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
        alert.messageText = String(format: L("alert.saveChanges.message"), workspace.windowTitle)
        alert.informativeText = L("alert.saveChanges.informative")
        alert.addButton(withTitle: L("alert.saveChanges.save"))
        alert.addButton(withTitle: L("alert.saveChanges.dontSave"))
        alert.addButton(withTitle: L("alert.saveChanges.cancel"))

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

private struct FileSaveCommands: View {
    @ObservedObject var workspace: ProjectWorkspace

    var body: some View {
        Button(L("menu.file.save")) {
            _ = workspace.saveOrPromptSaveAs()
        }
        .keyboardShortcut("s", modifiers: [.command])

        Button(L("menu.file.saveAs")) {
            _ = workspace.presentSavePanel()
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
    }
}

private struct FileImportExportCommands: View {
    @ObservedObject var workspace: ProjectWorkspace

    var body: some View {
        Button(L("menu.file.importMedia")) {
            workspace.presentImportMediaPanel()
        }
        .keyboardShortcut("i", modifiers: [.command])

        Button(L("menu.file.export")) {
            workspace.presentExportPanel()
        }
        .keyboardShortcut("e", modifiers: [.command])
    }
}

private struct PlaybackCommands: View {
    @ObservedObject var workspace: ProjectWorkspace

    var body: some View {
        Button(L("menu.playback.playPause")) {
            if workspace.preview.currentRequestedRate == 0 {
                workspace.playPreview()
            } else {
                workspace.pausePreview()
            }
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(workspace.isExporting)

        Button(L("menu.playback.stop")) {
            workspace.stopPreview()
        }
        .disabled(workspace.isExporting)

        Divider()

        Button(L("menu.playback.toggleLoop")) {
            workspace.isPreviewLooping.toggle()
        }
        .keyboardShortcut("l", modifiers: [.command])
        .disabled(workspace.isExporting)
    }
}

private struct RangeCommands: View {
    @ObservedObject var workspace: ProjectWorkspace

    var body: some View {
        Button(L("menu.range.setIn")) {
            workspace.updateTimelineRange(inSeconds: workspace.previewTimeSeconds, outSeconds: workspace.rangeOutSeconds)
        }

        Button(L("menu.range.setOut")) {
            workspace.updateTimelineRange(inSeconds: workspace.rangeInSeconds, outSeconds: workspace.previewTimeSeconds)
        }

        Divider()

        Button(L("menu.range.clear")) {
            workspace.clearTimelineRange()
        }
        .disabled(!workspace.hasRangeSelection)

        Button(L("menu.range.rippleDeleteRange")) {
            guard let r = workspace.normalizedRange else {
                NSSound.beep()
                return
            }
            Task {
                do {
                    try await workspace.store.rippleDeleteRange(inSeconds: r.inSeconds, outSeconds: r.outSeconds)
                    workspace.clearTimelineRange()
                } catch {
                    NSSound.beep()
                }
            }
        }
        .disabled(!workspace.hasRangeSelection)
    }
}

private struct TimelineCommands: View {
    @ObservedObject var workspace: ProjectWorkspace

    var body: some View {
        Button(L("menu.timeline.addVideoTrack")) {
            workspace.addVideoTrack()
        }

        Button(L("menu.timeline.addAudioTrack")) {
            workspace.addAudioTrack()
        }

        Divider()

        Button(workspace.isAudioComponentsExpanded ? L("menu.timeline.collapseAudioComponents") : L("menu.timeline.expandAudioComponents")) {
            workspace.toggleAudioComponentsExpanded()
        }
        .keyboardShortcut("a", modifiers: [.command, .option])

        Divider()

        Button(L("menu.timeline.toggleTrackMute")) {
            workspace.toggleMuteForTargetTrack()
        }
        .keyboardShortcut("m", modifiers: [.control])
        .disabled(!workspace.canToggleAudioTrackMuteSolo)

        Button(L("menu.timeline.toggleTrackSolo")) {
            workspace.toggleSoloForTargetTrack()
        }
        .keyboardShortcut("s", modifiers: [.control])
        .disabled(!workspace.canToggleAudioTrackMuteSolo)
    }
}

private struct ClipCommands: View {
    @ObservedObject var workspace: ProjectWorkspace

    var body: some View {
        let selectionCount = workspace.selectedClipIds.count
        let hasPrimary = workspace.primarySelectedClipId != nil
        let hasSelection = selectionCount > 0 || hasPrimary
        let deleteTitle = (selectionCount > 1)
        ? Lf("menu.deleteN", selectionCount)
        : L("menu.delete")
        let rippleTitle = (selectionCount > 1)
        ? Lf("menu.rippleDeleteN", selectionCount)
        : L("menu.rippleDelete")

        Button(L("menu.blade")) {
            workspace.bladeAtPlayhead()
        }
        .keyboardShortcut("b", modifiers: [.command])
        .disabled(!workspace.canSplitAtPlayhead)

        Button(L("menu.bladeAll")) {
            workspace.bladeAllAtPlayhead()
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .disabled(!workspace.canSplitAtPlayhead)

        Divider()

        Button(L("menu.increaseClipVolume")) {
            workspace.adjustClipVolumeAtPlayhead(delta: 0.1)
        }
        .keyboardShortcut("=", modifiers: [.option])
        .disabled(!workspace.canAdjustClipVolumeAtPlayhead)

        Button(L("menu.decreaseClipVolume")) {
            workspace.adjustClipVolumeAtPlayhead(delta: -0.1)
        }
        .keyboardShortcut("-", modifiers: [.option])
        .disabled(!workspace.canAdjustClipVolumeAtPlayhead)

        Divider()

        Button(rippleTitle) {
            workspace.deleteSelectedClips(ripple: true)
        }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(!hasSelection)

        Button(deleteTitle) {
            workspace.deleteSelectedClips(ripple: false)
        }
        .keyboardShortcut(.delete, modifiers: [.shift])
        .disabled(!hasSelection)

        Divider()

        Menu(L("menu.clip.spatialConform")) {
            Button(L("menu.clip.spatialConform.followProject")) {
                workspace.setSpatialConformOverrideForSelection(nil)
            }
            Divider()
            Button(L("menu.clip.spatialConform.fit")) {
                workspace.setSpatialConformOverrideForSelection(.fit)
            }
            Button(L("menu.clip.spatialConform.fill")) {
                workspace.setSpatialConformOverrideForSelection(.fill)
            }
            Button(L("menu.clip.spatialConform.none")) {
                workspace.setSpatialConformOverrideForSelection(SpatialConform.none)
            }
        }
        .disabled(!hasSelection)
    }
}

private struct UndoRedoCommands: View {
    @ObservedObject var store: EditorSessionStore
    let undo: () -> Void
    let redo: () -> Void

    var body: some View {
        let undoTitle = {
            if let name = store.undoActionName, !name.isEmpty {
                return Lf("menu.edit.undoWithName", name)
            }
            return L("menu.edit.undo")
        }()

        let redoTitle = {
            if let name = store.redoActionName, !name.isEmpty {
                return Lf("menu.edit.redoWithName", name)
            }
            return L("menu.edit.redo")
        }()

        Button(undoTitle, action: undo)
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(!store.canUndo)

        Button(redoTitle, action: redo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!store.canRedo)
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
        .sheet(isPresented: $workspace.isExportDialogPresented) {
            ExportDialogView(workspace: workspace)
        }
        .task {
            workspace.configurePlaybackIfNeeded()
            workspace.configurePreviewIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                let isPlaying = workspace.preview.currentRequestedRate != 0
                Button(isPlaying ? L("ui.toolbar.pause") : L("ui.toolbar.play")) {
                    if isPlaying {
                        workspace.pausePreview()
                    } else {
                        workspace.playPreview()
                    }
                }
                .disabled(workspace.isExporting)
                Button(L("menu.playback.stop")) {
                    workspace.stopPreview()
                }
                .disabled(workspace.isExporting)

                Button(L("menu.file.export")) {
                    workspace.presentExportPanel()
                }
                .disabled(workspace.isExporting)

                Toggle(L("ui.toolbar.loop"), isOn: $workspace.isPreviewLooping)

                if workspace.isExporting {
                    Text(Lf("ui.toolbar.exportPercent", workspace.exportProgress * 100))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                } else if !workspace.exportStatusText.isEmpty {
                    Text(workspace.exportStatusText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .lineLimit(1)
                }

                Divider()

                Button(L("ui.toolbar.addVideoTrack")) {
                    workspace.addVideoTrack()
                }
            }
        }
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
            alert.messageText = String(format: L("alert.saveChanges.message"), workspace.windowTitle)
            alert.informativeText = L("alert.saveChanges.informative")
            alert.addButton(withTitle: L("alert.saveChanges.save"))
            alert.addButton(withTitle: L("alert.saveChanges.dontSave"))
            alert.addButton(withTitle: L("alert.saveChanges.cancel"))

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
        case .currentTab: return L("ui.openTarget.currentTab")
        case .newTab: return L("ui.openTarget.newTab")
        case .newWindow: return L("ui.openTarget.newWindow")
        }
    }
}

private enum AppPreferences {
    static let newProjectOpenTargetKey = "pref.newProject.openTarget"
    static let openProjectOpenTargetKey = "pref.openProject.openTarget"
    static let canvasBackgroundKey = "pref.viewer.canvasBackground"
}

private enum CanvasBackgroundStyle: String, CaseIterable, Identifiable {
    case black
    case darkGray
    case window

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .black: return "ui.canvasBackground.black"
        case .darkGray: return "ui.canvasBackground.darkGray"
        case .window: return "ui.canvasBackground.window"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .black: return .black
        case .darkGray: return .darkGray
        case .window: return .windowBackgroundColor
        }
    }
}

private struct PreferencesView: View {
    @AppStorage(AppPreferences.newProjectOpenTargetKey) private var newProjectTargetRaw: String = OpenTarget.newTab.rawValue
    @AppStorage(AppPreferences.openProjectOpenTargetKey) private var openProjectTargetRaw: String = OpenTarget.newTab.rawValue
    @AppStorage(AppPreferences.canvasBackgroundKey) private var canvasBackgroundRaw: String = CanvasBackgroundStyle.black.rawValue

    var body: some View {
        Form {
            Picker(L("ui.preferences.newProjectOpenTarget"), selection: $newProjectTargetRaw) {
                ForEach(OpenTarget.allCases) { t in
                    Text(t.title).tag(t.rawValue)
                }
            }

            Picker(L("ui.preferences.openProjectOpenTarget"), selection: $openProjectTargetRaw) {
                ForEach(OpenTarget.allCases) { t in
                    Text(t.title).tag(t.rawValue)
                }
            }

            Picker(L("ui.preferences.canvasBackground"), selection: $canvasBackgroundRaw) {
                ForEach(CanvasBackgroundStyle.allCases) { style in
                    Text(L(style.titleKey)).tag(style.rawValue)
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

    private enum ClipConformSelection: String, CaseIterable, Identifiable {
        case followProject
        case fit
        case fill
        case none

        var id: String { rawValue }

        var overrideValue: SpatialConform? {
            switch self {
            case .followProject: return nil
            case .fit: return .fit
            case .fill: return .fill
            case .none: return SpatialConform.none
            }
        }

        static func fromOverride(_ value: SpatialConform?) -> ClipConformSelection {
            switch value {
            case nil: return .followProject
            case .some(.fit): return .fit
            case .some(.fill): return .fill
            case .some(.none): return .none
            }
        }

        var titleKey: String {
            switch self {
            case .followProject: return "ui.sidebar.spatialConform.followProject"
            case .fit: return "ui.sidebar.spatialConform.fit"
            case .fill: return "ui.sidebar.spatialConform.fill"
            case .none: return "ui.sidebar.spatialConform.none"
            }
        }
    }

    @State private var selectedAssetId: UUID?
    @State private var renamingAssetId: UUID?
    @State private var renameDraft: String = ""

    @FocusState private var renameFocusedAssetId: UUID?

    private func beginRenameSelectedAsset(project: Project) {
        guard let id = selectedAssetId,
              let asset = project.mediaAssets.first(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        renamingAssetId = id
        renameDraft = asset.displayName
        renameFocusedAssetId = id
    }

    var body: some View {
        let project = store.project
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.meta.name)
                Text(Lf("ui.sidebar.fps", project.meta.fps))
                Text("FPS: \(project.meta.fps, specifier: "%.0f")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox(L("ui.sidebar.spatialConform")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L("ui.sidebar.spatialConform.projectDefault"), selection: Binding(
                        get: { project.meta.spatialConformDefault },
                        set: { newValue in
                            workspace.setProjectSpatialConformDefault(newValue)
                        }
                    )) {
                        Text(L("ui.sidebar.spatialConform.fit")).tag(SpatialConform.fit)
                        Text(L("ui.sidebar.spatialConform.fill")).tag(SpatialConform.fill)
                        Text(L("ui.sidebar.spatialConform.none")).tag(SpatialConform.none)
                    }
                    .pickerStyle(.segmented)

                    if let primaryId = workspace.primarySelectedClipId {
                        let primaryClip = project.timeline.tracks
                            .flatMap { $0.clips }
                            .first(where: { $0.id == primaryId })

                        if let primaryClip {
                            Picker(L("ui.sidebar.spatialConform.clipOverride"), selection: Binding(
                                get: { ClipConformSelection.fromOverride(primaryClip.spatialConformOverride) },
                                set: { sel in
                                    workspace.setSpatialConformOverrideForPrimarySelection(sel.overrideValue)
                                }
                            )) {
                                ForEach(ClipConformSelection.allCases) { opt in
                                    Text(L(opt.titleKey)).tag(opt)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            GroupBox(L("ui.sidebar.media")) {
                if project.mediaAssets.isEmpty {
                    Text(L("ui.sidebar.noAssets"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    List(project.mediaAssets, id: \.id, selection: $selectedAssetId) { asset in
                        VStack(alignment: .leading, spacing: 2) {
                            if renamingAssetId == asset.id {
                                TextField(L("ui.sidebar.nameField"), text: $renameDraft)
                                    .textFieldStyle(.plain)
                                    .focused($renameFocusedAssetId, equals: asset.id)
                                    .onSubmit {
                                        let newName = renameDraft
                                        renamingAssetId = nil
                                        workspace.renameAsset(assetId: asset.id, displayName: newName)
                                    }
                                    .onExitCommand {
                                        renamingAssetId = nil
                                    }
                                    .onAppear {
                                        renameFocusedAssetId = asset.id
                                    }
                            } else {
                                Text(asset.displayName)
                                    .lineLimit(1)
                            }

                            Text(asset.originalPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contextMenu {
                            Button(L("menu.asset.rename")) {
                                renamingAssetId = asset.id
                                renameDraft = asset.displayName
                                renameFocusedAssetId = asset.id
                            }
                        }
                        .onDrag {
                            selectedAssetId = asset.id
                            return NSItemProvider(object: asset.id.uuidString as NSString)
                        }
                        .onTapGesture(count: 2) {
                            selectedAssetId = asset.id
                            renamingAssetId = asset.id
                            renameDraft = asset.displayName
                            renameFocusedAssetId = asset.id
                        }
                    }
                }

                HStack {
                    Button(L("menu.file.importMedia")) {
                        workspace.presentImportMediaPanel()
                    }

                    Button(L("ui.sidebar.addToVideoTrack")) {
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
            .overlay {
                KeyDownMonitorView(
                    onKeyDown: { event in
                        // F2 key
                        if event.keyCode == 120 {
                            if renamingAssetId == nil, selectedAssetId != nil {
                                beginRenameSelectedAsset(project: project)
                                return true
                            }
                        }
                        return false
                    }
                )
                .frame(width: 0, height: 0)
                .opacity(0)
            }

            GroupBox(L("ui.sidebar.tracks")) {
                if project.timeline.tracks.isEmpty {
                    Text(L("ui.sidebar.noTracks"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    List(Array(project.timeline.tracks.enumerated()), id: \.element.id) { index, track in
                        HStack {
                            Text("[\(index)] \(track.kind.rawValue)")
                            Spacer()
                            Text(Lf("ui.sidebar.clipsCount", track.clips.count))
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

private struct KeyDownMonitorView: NSViewRepresentable {
    typealias OnKeyDown = (NSEvent) -> Bool
    let onKeyDown: OnKeyDown

    private final class MonitorToken: @unchecked Sendable {
        let raw: Any
        init(_ raw: Any) {
            self.raw = raw
        }
    }

    final class HostingView: NSView {
        var onKeyDown: OnKeyDown
        private var monitor: MonitorToken?

        init(onKeyDown: @escaping OnKeyDown) {
            self.onKeyDown = onKeyDown
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let monitor {
                    NSEvent.removeMonitor(monitor.raw)
                    self.monitor = nil
                }
                return
            }

            if monitor == nil {
                let raw = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    if self.onKeyDown(event) {
                        return nil
                    }
                    return event
                }
                monitor = MonitorToken(raw as Any)
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor.raw)
            }
        }
    }

    func makeNSView(context: Context) -> HostingView {
        HostingView(onKeyDown: onKeyDown)
    }

    func updateNSView(_ nsView: HostingView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

private struct PreviewView: View {
    @ObservedObject var workspace: ProjectWorkspace

    @AppStorage(AppPreferences.canvasBackgroundKey) private var canvasBackgroundRaw: String = CanvasBackgroundStyle.black.rawValue

    private static let isMetalPreviewEnabled: Bool = {
        // Default to Metal for Apple Silicon-first performance & consistency.
        // Allow forcing the legacy path via env var for debugging/compat.
        let env = ProcessInfo.processInfo.environment["YUNQI_PREVIEW_RENDERER"]?.lowercased()
        if env == "avfoundation" || env == "legacy" || env == "player" {
            return false
        }
        return true
    }()

    var body: some View {
        let canvasBackground = CanvasBackgroundStyle(rawValue: canvasBackgroundRaw)?.nsColor ?? NSColor.black
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            if Self.isMetalPreviewEnabled {
                MetalPreviewViewRepresentable(
                    pixelBuffer: workspace.previewPixelBuffer,
                    quality: workspace.preview.currentRequestedRate == 0 ? .high : .realtime,
                    preferredTransform: workspace.previewPreferredTransform,
                    canvasBackgroundColor: canvasBackground,
                    canvasSize: CGSize(
                        width: workspace.store.project.meta.renderSize.width,
                        height: workspace.store.project.meta.renderSize.height
                    )
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlayerViewRepresentable(
                    player: workspace.preview.player,
                    overlayFrame: workspace.previewFrameImage
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
            isAudioComponentsExpanded: workspace.isAudioComponentsExpanded,
            selectedClipIds: workspace.selectedClipIds,
            primarySelectedClipId: workspace.primarySelectedClipId,
            rangeInSeconds: workspace.rangeInSeconds,
            rangeOutSeconds: workspace.rangeOutSeconds,
            onAddAssetToTimelineRequested: { assetId, timeSeconds, trackIndex in
                workspace.addAssetToTimeline(assetId: assetId, at: timeSeconds, targetTrackIndex: trackIndex)
            },
            onSelectionChanged: { selected, primary in
                workspace.updateTimelineSelection(selected: selected, primary: primary)
            },
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
            onSetClipVolumeRequested: { clipId, volume in
                Task {
                    do {
                        try await store.setClipVolume(clipId: clipId, volume: volume)
                    } catch {
                        NSSound.beep()
                    }
                }
            },
            onToggleTrackMuteRequested: { trackId in
                Task {
                    do {
                        try await store.toggleTrackMute(trackId: trackId)
                    } catch {
                        NSSound.beep()
                    }
                }
            },
            onToggleTrackSoloRequested: { trackId in
                Task {
                    do {
                        try await store.toggleTrackSolo(trackId: trackId)
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
            ,
            onRangeChanged: { a, b in
                workspace.updateTimelineRange(inSeconds: a, outSeconds: b)
            },
            onRippleDeleteRangeRequested: { a, b in
                Task {
                    do {
                        try await store.rippleDeleteRange(inSeconds: a, outSeconds: b)
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
    let isAudioComponentsExpanded: Bool
    let selectedClipIds: Set<UUID>
    let primarySelectedClipId: UUID?
    let rangeInSeconds: Double?
    let rangeOutSeconds: Double?
    let onAddAssetToTimelineRequested: (UUID, Double, Int?) -> Void
    let onSelectionChanged: (Set<UUID>, UUID?) -> Void
    let onMoveClipCommitted: (UUID, Double) -> Void
    let onMoveClipsCommitted: ([(clipId: UUID, startSeconds: Double)]) -> Void
    let onTrimClipCommitted: (UUID, Double?, Double?, Double?) -> Void
    let onScrubBegan: () -> Void
    let onScrubEnded: () -> Void
    let onSeekRequested: (Double) -> Void
    let onSetPlaybackRateRequested: (Float) -> Void
    let onSplitClipRequested: (UUID, Double) -> Void
    let onSetClipVolumeRequested: (UUID, Double) -> Void
    let onToggleTrackMuteRequested: (UUID) -> Void
    let onToggleTrackSoloRequested: (UUID) -> Void
    let onDeleteClipRequested: (UUID) -> Void
    let onDeleteClipsRequested: ([UUID]) -> Void
    let onRippleDeleteClipsRequested: ([UUID]) -> Void
    let onRangeChanged: (Double?, Double?) -> Void
    let onRippleDeleteRangeRequested: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let timelineView = TimelineNSView()
        timelineView.onAddAssetToTimelineRequested = onAddAssetToTimelineRequested
        timelineView.onSelectionChanged = onSelectionChanged
        timelineView.onMoveClipCommitted = onMoveClipCommitted
        timelineView.onMoveClipsCommitted = onMoveClipsCommitted
        timelineView.onTrimClipCommitted = onTrimClipCommitted
        timelineView.onScrubBegan = onScrubBegan
        timelineView.onScrubEnded = onScrubEnded
        timelineView.onSeekRequested = onSeekRequested
        timelineView.onSetPlaybackRateRequested = onSetPlaybackRateRequested
        timelineView.onSplitClipRequested = onSplitClipRequested
        timelineView.onSetClipVolumeRequested = onSetClipVolumeRequested
        timelineView.onToggleTrackMuteRequested = onToggleTrackMuteRequested
        timelineView.onToggleTrackSoloRequested = onToggleTrackSoloRequested
        timelineView.onDeleteClipRequested = onDeleteClipRequested
        timelineView.onDeleteClipsRequested = onDeleteClipsRequested
        timelineView.onRippleDeleteClipsRequested = onRippleDeleteClipsRequested
        timelineView.onRangeChanged = onRangeChanged
        timelineView.onRippleDeleteRangeRequested = onRippleDeleteRangeRequested

        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = timelineView

        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(scrollView: scroll, timelineView: timelineView)

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
        timelineView.isAudioComponentsExpanded = isAudioComponentsExpanded
        timelineView.onAddAssetToTimelineRequested = onAddAssetToTimelineRequested

        timelineView.setSelection(selected: selectedClipIds, primary: primarySelectedClipId, notify: false)

        timelineView.setRangeSelection(inSeconds: rangeInSeconds, outSeconds: rangeOutSeconds, notify: false)

        timelineView.onSelectionChanged = onSelectionChanged
        timelineView.onMoveClipCommitted = onMoveClipCommitted
        timelineView.onMoveClipsCommitted = onMoveClipsCommitted
        timelineView.onTrimClipCommitted = onTrimClipCommitted
        timelineView.onScrubBegan = onScrubBegan
        timelineView.onScrubEnded = onScrubEnded
        timelineView.onSeekRequested = onSeekRequested
        timelineView.onSetPlaybackRateRequested = onSetPlaybackRateRequested
        timelineView.onSplitClipRequested = onSplitClipRequested
        timelineView.onSetClipVolumeRequested = onSetClipVolumeRequested
        timelineView.onToggleTrackMuteRequested = onToggleTrackMuteRequested
        timelineView.onToggleTrackSoloRequested = onToggleTrackSoloRequested
        timelineView.onDeleteClipRequested = onDeleteClipRequested
        timelineView.onDeleteClipsRequested = onDeleteClipsRequested
        timelineView.onRippleDeleteClipsRequested = onRippleDeleteClipsRequested
        timelineView.onRangeChanged = onRangeChanged
        timelineView.onRippleDeleteRangeRequested = onRippleDeleteRangeRequested

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

        private var boundsObserver: NSObjectProtocol?

        @MainActor
        func attach(scrollView: NSScrollView, timelineView: TimelineNSView) {
            if boundsObserver != nil { return }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak timelineView, weak scrollView] _ in
                guard let timelineView, let scrollView else { return }
                Task { @MainActor in
                    timelineView.handleViewportChanged(scrollView: scrollView)
                }
            }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }
    }
}

private final class TimelineNSView: NSView {
    var project: Project = Project(meta: ProjectMeta(name: L("app.name"))) {
        didSet {
            window?.invalidateCursorRects(for: self)
            pruneMiniCaches()
        }
    }

    private func invalidateCursorRectsForSelf() {
        if let window {
            window.invalidateCursorRects(for: self)
        } else {
            discardCursorRects()
        }
    }
    var playheadSeconds: Double = 0
    var playerRate: Float = 0

    var isAudioComponentsExpanded: Bool = true {
        didSet {
            if oldValue != isAudioComponentsExpanded {
                needsDisplay = true
            }
        }
    }
    var onMoveClipCommitted: ((UUID, Double) -> Void)?
    var onMoveClipsCommitted: (([(clipId: UUID, startSeconds: Double)]) -> Void)?
    var onTrimClipCommitted: ((UUID, Double?, Double?, Double?) -> Void)?
    var onSelectionChanged: ((Set<UUID>, UUID?) -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?
    var onSeekRequested: ((Double) -> Void)?
    var onSetPlaybackRateRequested: ((Float) -> Void)?
    var onSplitClipRequested: ((UUID, Double) -> Void)?
    var onSetClipVolumeRequested: ((UUID, Double) -> Void)?
    var onToggleTrackMuteRequested: ((UUID) -> Void)?
    var onToggleTrackSoloRequested: ((UUID) -> Void)?
    var onDeleteClipRequested: ((UUID) -> Void)?
    var onDeleteClipsRequested: (([UUID]) -> Void)?
    var onRippleDeleteClipsRequested: (([UUID]) -> Void)?
    var onRangeChanged: ((Double?, Double?) -> Void)?
    var onRippleDeleteRangeRequested: ((Double, Double) -> Void)?
    var onAddAssetToTimelineRequested: ((UUID, Double, Int?) -> Void)?

    private var selectedClipIds: Set<UUID> = []
    private var primarySelectedClipId: UUID?
    
    func setSelection(selected: Set<UUID>, primary: UUID?, notify: Bool) {
        selectedClipIds = selected
        primarySelectedClipId = primary
        if notify {
            onSelectionChanged?(selectedClipIds, primarySelectedClipId)
        }
        needsDisplay = true
    }

    func setRangeSelection(inSeconds: Double?, outSeconds: Double?, notify: Bool) {
        rangeInSeconds = inSeconds
        rangeOutSeconds = outSeconds
        rangeDraggingStartSeconds = nil
        if normalizedRange() == nil {
            rangeHoveredBoundary = nil
        }
        if notify {
            onRangeChanged?(rangeInSeconds, rangeOutSeconds)
        }
        invalidateCursorRectsForSelf()
        updateTrackingAreas()
        needsDisplay = true
    }
    private var dragging: DragState?
    private var scrubbing: ScrubState?
    private var scrubPreviewSeconds: Double?
    private var marquee: MarqueeState?
    private var dragPreviewStartSeconds: [UUID: Double] = [:]
    private var dragPreviewDurationSeconds: [UUID: Double] = [:]
    private var dragPreviewSourceInSeconds: [UUID: Double] = [:]
    private var snapGuideSeconds: Double? = nil
    private var snappingEnabled: Bool = true

    // External asset drag preview (from sidebar)
    private var externalDropPreviewSeconds: Double? = nil

    private var rangeToolEnabled: Bool = false
    private var rangeInSeconds: Double? = nil
    private var rangeOutSeconds: Double? = nil
    private var rangeDraggingStartSeconds: Double? = nil
    private var rangeDraggingMovesIn: Bool = false

    private enum RangeBoundaryHover {
        case rangeIn
        case rangeOut
    }

    private var rangeTrackingArea: NSTrackingArea?
    private var rangeHoveredBoundary: RangeBoundaryHover? = nil

    private struct JKLKeysDown {
        var j: Bool = false
        var k: Bool = false
        var l: Bool = false
    }

    private var jklKeysDown: JKLKeysDown = JKLKeysDown()

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .string,
            NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
            NSPasteboard.PasteboardType(UTType.utf16PlainText.identifier),
            NSPasteboard.PasteboardType(UTType.plainText.identifier),
            NSPasteboard.PasteboardType(UTType.text.identifier)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([
            .string,
            NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
            NSPasteboard.PasteboardType(UTType.utf16PlainText.identifier),
            NSPasteboard.PasteboardType(UTType.plainText.identifier),
            NSPasteboard.PasteboardType(UTType.text.identifier)
        ])
    }

    func handleViewportChanged(scrollView: NSScrollView) {
        resizeToFit(scrollView: scrollView)
        needsDisplay = true
        invalidateCursorRectsForSelf()
        updateTrackingAreas()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // When the window is resized, AppKit may not always trigger a full redraw of newly exposed areas
        // for our custom-scrolling NSView. Force a redraw and refresh hover/cursor affordances.
        needsDisplay = true
        invalidateCursorRectsForSelf()
        updateTrackingAreas()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
        invalidateCursorRectsForSelf()
        updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    private func assetIdFromDraggingPasteboard(_ pb: NSPasteboard) -> UUID? {
        func normalize(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("urn:uuid:") {
                s = String(s.dropFirst("urn:uuid:".count))
            }
            if s.hasPrefix("{") && s.hasSuffix("}") && s.count > 2 {
                s = String(s.dropFirst().dropLast())
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let candidateTypes: [NSPasteboard.PasteboardType] = [
            .string,
            NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
            NSPasteboard.PasteboardType(UTType.utf16PlainText.identifier),
            NSPasteboard.PasteboardType(UTType.plainText.identifier),
            NSPasteboard.PasteboardType(UTType.text.identifier)
        ]

        for t in candidateTypes {
            if let raw = pb.string(forType: t) {
                let s = normalize(raw)
                if let id = UUID(uuidString: s) {
                    return id
                }
            }
        }

        if let objs = pb.readObjects(forClasses: [NSString.self], options: nil) as? [NSString],
           let first = objs.first
        {
            let s = normalize(first as String)
            if let id = UUID(uuidString: s) {
                return id
            }
        }

        #if DEBUG
        let types = pb.types?.map { $0.rawValue }.joined(separator: ", ") ?? "(nil)"
        NSLog("[DND] Could not decode asset UUID. Pasteboard types: \(types)")
        #endif

        return nil
    }

    private func isDragFromSidebarAsset(_ sender: NSDraggingInfo) -> Bool {
        assetIdFromDraggingPasteboard(sender.draggingPasteboard) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isDragFromSidebarAsset(sender) {
            return .copy
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isDragFromSidebarAsset(sender) else {
            externalDropPreviewSeconds = nil
            snapGuideSeconds = nil
            needsDisplay = true
            return []
        }

        let pointInView = convert(sender.draggingLocation, from: nil)
        let proposed = max(0, seconds(atX: pointInView.x))
        let optionDown = NSEvent.modifierFlags.contains(.option)
        let snap = snapStartSeconds(proposed, movingClipIds: [], snappingEnabled: snappingEnabled && !optionDown)

        externalDropPreviewSeconds = snap.value
        snapGuideSeconds = snap.target
        needsDisplay = true
        return .copy
    }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            externalDropPreviewSeconds = nil
            snapGuideSeconds = nil
            needsDisplay = true
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            guard let assetId = assetIdFromDraggingPasteboard(pb) else {
                return false
            }

            let pointInView = convert(sender.draggingLocation, from: nil)
            let proposed = max(0, seconds(atX: pointInView.x))
            let optionDown = NSEvent.modifierFlags.contains(.option)
            let snap = snapStartSeconds(proposed, movingClipIds: [], snappingEnabled: snappingEnabled && !optionDown)
            let timeSeconds = snap.value

            onAddAssetToTimelineRequested?(assetId, timeSeconds, nil)
            externalDropPreviewSeconds = nil
            snapGuideSeconds = nil
            needsDisplay = true
            return true
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            externalDropPreviewSeconds = nil
            snapGuideSeconds = nil
            needsDisplay = true
        }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let rangeTrackingArea {
            removeTrackingArea(rangeTrackingArea)
            self.rangeTrackingArea = nil
        }

        let shouldTrack = rangeToolEnabled && normalizedRange() != nil
        if shouldTrack {
            let opts: NSTrackingArea.Options = [
                .activeInKeyWindow,
                .mouseMoved,
                .mouseEnteredAndExited,
                .inVisibleRect
            ]
            let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
            addTrackingArea(area)
            rangeTrackingArea = area
        } else {
            rangeHoveredBoundary = nil
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard rangeToolEnabled, let (a, b) = normalizedRange() else {
            if rangeHoveredBoundary != nil {
                rangeHoveredBoundary = nil
                invalidateCursorRectsForSelf()
                needsDisplay = true
            }
            super.mouseMoved(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= laneX else {
            if rangeHoveredBoundary != nil {
                rangeHoveredBoundary = nil
                invalidateCursorRectsForSelf()
                needsDisplay = true
            }
            super.mouseMoved(with: event)
            return
        }

        let s = seconds(atX: point.x)
        let grabThresholdSeconds = Double(max(handleHitWidthPx, snapThresholdPx) / pxPerSecond)

        let hovered: RangeBoundaryHover?
        if abs(s - a) <= grabThresholdSeconds {
            hovered = .rangeIn
        } else if abs(s - b) <= grabThresholdSeconds {
            hovered = .rangeOut
        } else {
            hovered = nil
        }

        if hovered != rangeHoveredBoundary {
            rangeHoveredBoundary = hovered
            invalidateCursorRectsForSelf()
            needsDisplay = true
        }

        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if rangeHoveredBoundary != nil {
            rangeHoveredBoundary = nil
            invalidateCursorRectsForSelf()
            needsDisplay = true
        }
        super.mouseExited(with: event)
    }

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

        // Range selection drag (when tool enabled)
        if rangeToolEnabled, point.x >= laneX, event.clickCount == 1 {
            let s = seconds(atX: point.x)
            if let (a, b) = normalizedRange() {
                // If the mouse is near an existing boundary, adjust that boundary even if outside the range.
                let grabThresholdSeconds = Double(max(handleHitWidthPx, snapThresholdPx) / pxPerSecond)

                if abs(s - a) <= grabThresholdSeconds {
                    // Near In
                    rangeDraggingMovesIn = true
                    rangeDraggingStartSeconds = b
                    rangeInSeconds = s
                    rangeOutSeconds = b
                } else if abs(s - b) <= grabThresholdSeconds {
                    // Near Out
                    rangeDraggingMovesIn = false
                    rangeDraggingStartSeconds = a
                    rangeInSeconds = a
                    rangeOutSeconds = s
                } else if s >= a, s <= b {
                    // Inside range: pick the nearer boundary as the moving edge.
                    let distToIn = abs(s - a)
                    let distToOut = abs(s - b)
                    if distToIn <= distToOut {
                        // Move in, anchor at out.
                        rangeDraggingMovesIn = true
                        rangeDraggingStartSeconds = b
                        rangeInSeconds = s
                        rangeOutSeconds = b
                    } else {
                        // Move out, anchor at in.
                        rangeDraggingMovesIn = false
                        rangeDraggingStartSeconds = a
                        rangeInSeconds = a
                        rangeOutSeconds = s
                    }
                } else {
                    // Outside and not near boundary: create a new range.
                    rangeDraggingMovesIn = false
                    rangeDraggingStartSeconds = s
                    rangeInSeconds = s
                    rangeOutSeconds = s
                }
            } else {
                // Create a new range.
                rangeDraggingMovesIn = false
                rangeDraggingStartSeconds = s
                rangeInSeconds = s
                rangeOutSeconds = s
            }
            onRangeChanged?(rangeInSeconds, rangeOutSeconds)

            snapGuideSeconds = nil

            // Cancel other interactions
            dragging = nil
            scrubbing = nil
            scrubPreviewSeconds = nil
            marquee = nil
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

            onSelectionChanged?(selectedClipIds, primarySelectedClipId)
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

            onSelectionChanged?(selectedClipIds, primarySelectedClipId)

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
        if let start = rangeDraggingStartSeconds {
            let point = convert(event.locationInWindow, from: nil)
            var s = seconds(atX: point.x)
            let snappingActive = snappingEnabled && !event.modifierFlags.contains(.option)
            snapGuideSeconds = nil
            if snappingActive {
                let snap = snapStartSeconds(s, movingClipIds: [], snappingEnabled: true)
                s = snap.value
                snapGuideSeconds = snap.target
            }
            if rangeDraggingMovesIn {
                rangeInSeconds = s
                rangeOutSeconds = start
            } else {
                rangeInSeconds = start
                rangeOutSeconds = s
            }
            onRangeChanged?(rangeInSeconds, rangeOutSeconds)
            invalidateCursorRectsForSelf()
            needsDisplay = true
            return
        }

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

                onSelectionChanged?(selectedClipIds, primarySelectedClipId)
            }
            needsDisplay = true
            return
        }

        guard let dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragging.mouseDownPoint.x
        let deltaSeconds = Double(dx / pxPerSecond)
        let snappingActive = snappingEnabled && !event.modifierFlags.contains(.option)
        snapGuideSeconds = nil

        switch dragging.mode {
        case .move:
            let movingIds: Set<UUID> = {
                if dragging.selectedOriginalStarts.isEmpty { return [dragging.clipId] }
                return Set(dragging.selectedOriginalStarts.keys).union([dragging.clipId])
            }()

            let proposed = max(0, dragging.originalStartSeconds + deltaSeconds)
            let snap = snapStartSeconds(
                proposed,
                movingClipIds: movingIds,
                snappingEnabled: snappingActive
            )
            let delta = snap.value - dragging.originalStartSeconds
            snapGuideSeconds = snap.target

            if !dragging.selectedOriginalStarts.isEmpty {
                for (id, start) in dragging.selectedOriginalStarts {
                    dragPreviewStartSeconds[id] = max(0, start + delta)
                }
            }
            dragPreviewStartSeconds[dragging.clipId] = max(0, dragging.originalStartSeconds + delta)

        case .trimLeft:
            let originalStart = dragging.originalStartSeconds
            let originalSourceIn = dragging.originalSourceInSeconds
            let originalDuration = dragging.originalDurationSeconds

            let endSeconds = originalStart + originalDuration
            var proposedStart = originalStart + deltaSeconds
            proposedStart = max(0, proposedStart)
            proposedStart = min(proposedStart, endSeconds - minClipDurationSeconds)

            let snap = snapStartSeconds(
                proposedStart,
                movingClipIds: [dragging.clipId],
                snappingEnabled: snappingActive
            )
            proposedStart = min(max(0, snap.value), endSeconds - minClipDurationSeconds)
            snapGuideSeconds = snap.target

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

            let snap = snapEndSeconds(
                proposedEnd,
                trimmingClipId: dragging.clipId,
                snappingEnabled: snappingActive
            )
            proposedEnd = max(snap.value, originalStart + minClipDurationSeconds)
            snapGuideSeconds = snap.target

            let newDuration = max(minClipDurationSeconds, proposedEnd - originalStart)
            dragPreviewDurationSeconds[dragging.clipId] = newDuration
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if rangeDraggingStartSeconds != nil {
            rangeDraggingStartSeconds = nil
            rangeDraggingMovesIn = false
            snapGuideSeconds = nil
            needsDisplay = true
            return
        }

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
        let snappingActive = snappingEnabled && !event.modifierFlags.contains(.option)
        snapGuideSeconds = nil

        switch dragging.mode {
        case .move:
            let proposed = max(0, dragging.originalStartSeconds + deltaSeconds)
            let movingIds: Set<UUID> = {
                if dragging.selectedOriginalStarts.isEmpty { return [dragging.clipId] }
                return Set(dragging.selectedOriginalStarts.keys).union([dragging.clipId])
            }()
            let snap = snapStartSeconds(proposed, movingClipIds: movingIds, snappingEnabled: snappingActive)
            let snapped = snap.value

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
            let snap = snapStartSeconds(proposedStart, movingClipIds: [dragging.clipId], snappingEnabled: snappingActive)
            let snappedStart = snap.value

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
            let snap = snapEndSeconds(proposedEnd, trimmingClipId: dragging.clipId, snappingEnabled: snappingActive)
            let snappedEnd = snap.value

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

            var flags: [String] = []
            if track.isMuted { flags.append("M") }
            if track.isSolo { flags.append("S") }
            let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ","))]"
            let label = "\(index)  \(track.kind.rawValue)\(suffix)"
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
                    if isAudioComponentsExpanded {
                        // Final Cut-style: show audio as an embedded component lane inside the video clip.
                        let minAudioComponentHeight: CGFloat = 10
                        let audioH = min(rect.height * 0.45, rect.height - 8)
                        if audioH >= minAudioComponentHeight {
                            let audioRect = CGRect(x: rect.minX, y: rect.maxY - audioH, width: rect.width, height: audioH)
                            let videoRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - audioH))

                            drawVideoThumbnails(in: videoRect, clip: clip)

                            let anySolo = project.timeline.tracks.contains { $0.isSolo }
                            let audible = (!track.isMuted) && (!anySolo || track.isSolo)
                            if let ctx {
                                ctx.saveGState()
                                if !audible {
                                    ctx.setAlpha(0.25)
                                }
                                drawAudioWaveform(in: audioRect, clip: clip)
                                ctx.restoreGState()
                            } else {
                                drawAudioWaveform(in: audioRect, clip: clip)
                            }

                            // Divider line between video and audio components.
                            ctx?.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.20).cgColor)
                            ctx?.setLineWidth(1)
                            ctx?.move(to: CGPoint(x: rect.minX, y: audioRect.minY))
                            ctx?.addLine(to: CGPoint(x: rect.maxX, y: audioRect.minY))
                            ctx?.strokePath()
                        } else {
                            drawVideoThumbnails(in: rect, clip: clip)
                        }
                    } else {
                        // Collapsed: fill the whole clip with video thumbnails.
                        drawVideoThumbnails(in: rect, clip: clip)
                    }
                case .audio:
                    if isAudioComponentsExpanded {
                        // Fade waveform when audio is effectively not audible.
                        let anySolo = project.timeline.tracks.contains { $0.isSolo }
                        let audible = (!track.isMuted) && (!anySolo || track.isSolo)
                        if let ctx {
                            ctx.saveGState()
                            if !audible {
                                ctx.setAlpha(0.25)
                            }
                            drawAudioWaveform(in: rect, clip: clip)
                            ctx.restoreGState()
                        } else {
                            drawAudioWaveform(in: rect, clip: clip)
                        }
                    }
                default:
                    break
                }

                ctx?.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
                ctx?.stroke(rect, width: 1)

                // Audio gain label (only when not default).
                if abs(clip.volume - 1.0) > 1e-9 {
                    let v = max(0, min(2.0, clip.volume))
                    let text = String(format: "%.0f%%", v * 100)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                    let size = (text as NSString).size(withAttributes: attrs)
                    let p = CGPoint(x: rect.maxX - size.width - 4, y: rect.minY + 2)
                    text.draw(at: p, withAttributes: attrs)
                }

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

        // Range selection overlay (Final Cut-style): translucent band over the lane area.
        if let (a, b) = normalizedRange(), let ctx {
            let x0 = laneX + CGFloat(a) * pxPerSecond
            let x1 = laneX + CGFloat(b) * pxPerSecond
            let left = min(x0, x1)
            let right = max(x0, x1)
            let w = max(1, right - left)

            let band = CGRect(
                x: left,
                y: inset,
                width: w,
                height: max(0, bounds.height - inset * 2)
            )

            ctx.saveGState()
            // Clip to lane area (exclude track labels).
            ctx.addRect(CGRect(x: laneX, y: inset, width: bounds.width - laneX, height: max(0, bounds.height - inset)))
            ctx.clip()

            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.12).cgColor)
            ctx.fill(band)

            let baseColor = NSColor.systemYellow
            let baseAlpha: CGFloat = 0.70
            let hoverAlpha: CGFloat = 0.95
            let baseWidth: CGFloat = 1
            let hoverWidth: CGFloat = 2

            let hover = rangeHoveredBoundary

            // In boundary
            ctx.setStrokeColor(baseColor.withAlphaComponent(hover == .rangeIn ? hoverAlpha : baseAlpha).cgColor)
            ctx.setLineWidth(hover == .rangeIn ? hoverWidth : baseWidth)
            ctx.move(to: CGPoint(x: band.minX + 0.5, y: band.minY))
            ctx.addLine(to: CGPoint(x: band.minX + 0.5, y: band.maxY))
            ctx.strokePath()

            // Out boundary
            ctx.setStrokeColor(baseColor.withAlphaComponent(hover == .rangeOut ? hoverAlpha : baseAlpha).cgColor)
            ctx.setLineWidth(hover == .rangeOut ? hoverWidth : baseWidth)
            ctx.move(to: CGPoint(x: band.maxX - 0.5, y: band.minY))
            ctx.addLine(to: CGPoint(x: band.maxX - 0.5, y: band.maxY))
            ctx.strokePath()

            ctx.restoreGState()
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

        // External drop preview line (drawn in timeline area)
        if let preview = externalDropPreviewSeconds, let ctx {
            let px = laneX + CGFloat(max(0, preview)) * pxPerSecond
            if px >= laneX - 2, px <= bounds.maxX + 2 {
                ctx.setStrokeColor(NSColor.selectedControlColor.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: px, y: inset))
                ctx.addLine(to: CGPoint(x: px, y: bounds.maxY - inset))
                ctx.strokePath()
            }
        }

        // Snap guide overlay (drawn in timeline area)
        if let snap = snapGuideSeconds {
            let gx = laneX + CGFloat(max(0, snap)) * pxPerSecond
            if gx >= laneX - 2, gx <= bounds.maxX + 2 {
                ctx?.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.9).cgColor)
                ctx?.setLineWidth(1)
                ctx?.move(to: CGPoint(x: gx, y: inset))
                ctx?.addLine(to: CGPoint(x: gx, y: bounds.maxY - inset))
                ctx?.strokePath()
            }
        }

        if project.timeline.tracks.isEmpty {
            let text = L("ui.timeline.placeholder")
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

        // Range boundary resize cursor (discoverability)
        if rangeToolEnabled, let (a, b) = normalizedRange() {
            let handleW = handleHitWidthPx
            let xIn = laneX + CGFloat(max(0, a)) * pxPerSecond
            let xOut = laneX + CGFloat(max(0, b)) * pxPerSecond

            let inHandle = CGRect(x: xIn - handleW / 2, y: 0, width: handleW, height: bounds.height)
            let outHandle = CGRect(x: xOut - handleW / 2, y: 0, width: handleW, height: bounds.height)
            addCursorRect(inHandle, cursor: .resizeLeftRight)
            addCursorRect(outHandle, cursor: .resizeLeftRight)
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func selectAll(_ sender: Any?) {
        let ordered = project.timeline.tracks
            .flatMap { $0.clips }
            .sorted {
                if $0.timelineStartSeconds != $1.timelineStartSeconds {
                    return $0.timelineStartSeconds < $1.timelineStartSeconds
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        setSelection(
            selected: Set(ordered.map { $0.id }),
            primary: ordered.first?.id,
            notify: true
        )
    }

    override func cancelOperation(_ sender: Any?) {
        setSelection(selected: [], primary: nil, notify: true)
        clearRangeSelection(notify: true)
    }

    override func keyDown(with event: NSEvent) {
        // Track mute/solo (Control+M / Control+S)
        if event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars.count == 1
        {
            let t = playheadSeconds
            if chars == "m" {
                if let trackId = trackIdForPrimaryOrPlayhead(timeSeconds: t) {
                    onToggleTrackMuteRequested?(trackId)
                    return
                }
            }
            if chars == "s" {
                if let trackId = trackIdForPrimaryOrPlayhead(timeSeconds: t) {
                    onToggleTrackSoloRequested?(trackId)
                    return
                }
            }
        }

        // Clip volume (Option +/-)
        if event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1
        {
            let key = chars
            if key == "=" || key == "+" {
                adjustClipVolumeAtPlayhead(delta: 0.1)
                return
            }
            if key == "-" {
                adjustClipVolumeAtPlayhead(delta: -0.1)
                return
            }
        }

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

        // Toggle snapping (Final Cut muscle memory: N)
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "n" {
            snappingEnabled.toggle()
            snapGuideSeconds = nil
            needsDisplay = true
            return
        }

        // Range Selection tool (Final Cut muscle memory: R)
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "r" {
            rangeToolEnabled.toggle()
            rangeDraggingStartSeconds = nil
            if !rangeToolEnabled {
                rangeHoveredBoundary = nil
            }
            invalidateCursorRectsForSelf()
            updateTrackingAreas()
            needsDisplay = true
            return
        }

        // Delete / Ripple Delete
        // Default Delete: ripple delete (NLE-style).
        // Shift+Delete: plain delete (leave gap).
        if event.keyCode == 51 || event.keyCode == 117 {
            if selectedClipIds.isEmpty, primarySelectedClipId == nil, let (a, b) = normalizedRange() {
                onRippleDeleteRangeRequested?(a, b)
                clearRangeSelection(notify: true)
                return
            }
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
            // IMPORTANT: Don't intercept Cmd+B / Shift+Cmd+B here; let menu shortcuts handle them
            // so we can support Final Cut-style "Blade" vs "Blade All" behavior.
            if event.modifierFlags.contains(.command) {
                break
            }
            let t = playheadSeconds
            if let id = primarySelectedClipId ?? clipIdIntersectingPlayhead(timeSeconds: t) {
                onSplitClipRequested?(id, t)
                return
            }
        case "i":
            setRangeIn(seconds: playheadSeconds, notify: true)
            return
        case "o":
            setRangeOut(seconds: playheadSeconds, notify: true)
            return
        case "x":
            clearRangeSelection(notify: true)
            return
        case "j":
            jklKeysDown.j = true
            // If K is held, play at half-speed (Final Cut-style).
            if jklKeysDown.k {
                onSetPlaybackRateRequested?(-0.5)
                return
            }
            // Repeat should advance the shuttle speed; this is already handled by nextJKLRate.
            onSetPlaybackRateRequested?(nextJKLRate(direction: -1))
        case "k":
            jklKeysDown.k = true
            // Holding K acts like a momentary stop, unless combined with J/L for half-speed.
            if jklKeysDown.j {
                onSetPlaybackRateRequested?(-0.5)
                return
            }
            if jklKeysDown.l {
                onSetPlaybackRateRequested?(0.5)
                return
            }
            onSetPlaybackRateRequested?(0)
        case "l":
            jklKeysDown.l = true
            // If K is held, play at half-speed (Final Cut-style).
            if jklKeysDown.k {
                onSetPlaybackRateRequested?(0.5)
                return
            }
            // Repeat should advance the shuttle speed; this is already handled by nextJKLRate.
            onSetPlaybackRateRequested?(nextJKLRate(direction: 1))
        case ",":
            stepFrames(-1)
        case ".":
            stepFrames(1)
        default:
            super.keyDown(with: event)
        }
    }

    private func adjustClipVolumeAtPlayhead(delta: Double) {
        let t = playheadSeconds
        guard let clipId = primarySelectedClipId ?? clipIdContaining(timeSeconds: t) else {
            NSSound.beep()
            return
        }

        let current = clipVolume(clipId: clipId) ?? 1.0
        let next = max(0, min(2.0, current + delta))
        onSetClipVolumeRequested?(clipId, next)
    }

    private func clipIdContaining(timeSeconds t: Double) -> UUID? {
        for track in project.timeline.tracks {
            for clip in track.clips {
                let start = clip.timelineStartSeconds
                let end = start + clip.durationSeconds
                guard t >= start, t <= end else { continue }
                return clip.id
            }
        }
        return nil
    }

    private func trackIdForPrimaryOrPlayhead(timeSeconds t: Double) -> UUID? {
        if let primarySelectedClipId {
            for track in project.timeline.tracks {
                if track.clips.contains(where: { $0.id == primarySelectedClipId }) {
                    return track.id
                }
            }
        }
        for track in project.timeline.tracks {
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
        for track in project.timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                return clip.volume
            }
        }
        return nil
    }

    override func keyUp(with event: NSEvent) {
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 {
            let key = chars
            if key == "j" {
                jklKeysDown.j = false
            } else if key == "k" {
                jklKeysDown.k = false
            } else if key == "l" {
                jklKeysDown.l = false
            } else {
                super.keyUp(with: event)
                return
            }

            // Recompute desired rate based on remaining held keys.
            if jklKeysDown.k {
                if jklKeysDown.j {
                    onSetPlaybackRateRequested?(-0.5)
                } else if jklKeysDown.l {
                    onSetPlaybackRateRequested?(0.5)
                } else {
                    onSetPlaybackRateRequested?(0)
                }
            } else {
                if jklKeysDown.j {
                    onSetPlaybackRateRequested?(nextJKLRate(direction: -1))
                } else if jklKeysDown.l {
                    onSetPlaybackRateRequested?(nextJKLRate(direction: 1))
                } else {
                    onSetPlaybackRateRequested?(0)
                }
            }
            return
        }

        super.keyUp(with: event)
    }

    // MARK: - Range selection helpers

    private func normalizedRange() -> (Double, Double)? {
        guard let a = rangeInSeconds, let b = rangeOutSeconds else { return nil }
        let lo = max(0, min(a, b))
        let hi = max(0, max(a, b))
        if hi - lo < 1e-9 { return nil }
        return (lo, hi)
    }

    private func setRangeIn(seconds: Double, notify: Bool) {
        rangeInSeconds = seconds
        if rangeOutSeconds == nil {
            rangeOutSeconds = seconds
        }
        rangeDraggingStartSeconds = nil
        if notify {
            onRangeChanged?(rangeInSeconds, rangeOutSeconds)
        }
        invalidateCursorRectsForSelf()
        updateTrackingAreas()
        needsDisplay = true
    }

    private func setRangeOut(seconds: Double, notify: Bool) {
        rangeOutSeconds = seconds
        if rangeInSeconds == nil {
            rangeInSeconds = seconds
        }
        rangeDraggingStartSeconds = nil
        if notify {
            onRangeChanged?(rangeInSeconds, rangeOutSeconds)
        }
        invalidateCursorRectsForSelf()
        updateTrackingAreas()
        needsDisplay = true
    }

    private func clearRangeSelection(notify: Bool) {
        rangeInSeconds = nil
        rangeOutSeconds = nil
        rangeDraggingStartSeconds = nil
        rangeDraggingMovesIn = false
        rangeHoveredBoundary = nil
        if notify {
            onRangeChanged?(nil, nil)
        }
        invalidateCursorRectsForSelf()
        updateTrackingAreas()
        needsDisplay = true
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

    private func clipIdIntersectingPlayhead(timeSeconds t: Double) -> UUID? {
        for track in project.timeline.tracks {
            for clip in track.clips {
                let start = clip.timelineStartSeconds
                let end = start + clip.durationSeconds
                // Match EditorCore: must split strictly inside clip bounds, and avoid too-small results.
                guard t > start, t < end else { continue }
                if (t - start) < minClipDurationSeconds { continue }
                if (end - t) < minClipDurationSeconds { continue }
                return clip.id
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
    private var waveformNoAudio: Set<UUID> = []

    private lazy var persistentWaveformCache: Storage.WaveformCache = {
        let fm = FileManager.default
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = caches
            .appendingPathComponent("yunqi", isDirectory: true)
            .appendingPathComponent("waveforms", isDirectory: true)
        return Storage.WaveformCache(baseURL: dir)
    }()

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

        // Background for waveform area (helps separation from thumbnails/clip fill).
        ctx.saveGState()
        ctx.addRect(rect)
        ctx.clip()
        ctx.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor)
        ctx.fill(rect)

        // Center line.
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.midY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        ctx.strokePath()
        ctx.restoreGState()

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
        if waveformNoAudio.contains(clip.id) { return }
        guard let url = assetURL(for: clip.assetId) else { return }

        waveformInFlight.insert(clip.id)
        let clipId = clip.id
        let start = max(0, clip.sourceInSeconds)
        let duration = max(0.05, clip.durationSeconds * max(0.0001, clip.speed))

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let samples = await self.generateWaveform(assetId: clip.assetId, url: url, startSeconds: start, durationSeconds: duration, desiredCount: desiredCount)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.waveformInFlight.remove(clipId)
                if let samples {
                    self.waveformNoAudio.remove(clipId)
                    self.waveformCache[clipId] = Waveform(count: desiredCount, samples: samples)
                    self.needsDisplay = true
                } else {
                    // Negative cache: avoid repeatedly probing audio tracks for video-only assets.
                    self.waveformNoAudio.insert(clipId)
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
        assetId: UUID,
        url: URL,
        startSeconds: Double,
        durationSeconds: Double,
        desiredCount: Int
    ) async -> [Float]? {
        let count = max(16, min(256, desiredCount))
        do {
            let base = try await persistentWaveformCache.loadOrCompute(
                assetId: assetId,
                url: url,
                startSeconds: max(0, startSeconds),
                durationSeconds: max(0.05, durationSeconds)
            )
            let resampled = persistentWaveformCache.resampled(base, desiredCount: count)
            return resampled.peak
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
        waveformNoAudio = waveformNoAudio.filter { live.contains($0) }
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

    private struct SnapResult {
        let value: Double
        let target: Double?
    }

    private func snapStartSeconds(_ proposed: Double, movingClipIds: Set<UUID>, snappingEnabled: Bool) -> SnapResult {
        guard snappingEnabled else { return SnapResult(value: proposed, target: nil) }
        let thresholdSeconds = Double(snapThresholdPx / pxPerSecond)

        var best = proposed
        var bestDist = Double.greatestFiniteMagnitude
        var bestTarget: Double? = nil

        func consider(_ candidate: Double) {
            let dist = abs(proposed - candidate)
            if dist < bestDist {
                bestDist = dist
                best = candidate
                bestTarget = candidate
            }
        }

        // Snap to 0 / playhead / ruler ticks.
        consider(0)
        consider(max(0, playheadSeconds))
        let minor = timeRulerMinorSpacingSeconds()
        if minor > 0 {
            consider((proposed / minor).rounded() * minor)
        }

        // Snap to other clips' start/end (across all tracks).
        for track in project.timeline.tracks {
            for clip in track.clips where !movingClipIds.contains(clip.id) {
                consider(clip.timelineStartSeconds)
                consider(clip.timelineStartSeconds + clip.durationSeconds)
            }
        }

        if bestDist <= thresholdSeconds {
            return SnapResult(value: best, target: bestTarget)
        }
        return SnapResult(value: proposed, target: nil)
    }

    private func snapEndSeconds(_ proposedEnd: Double, trimmingClipId: UUID, snappingEnabled: Bool) -> SnapResult {
        guard snappingEnabled else { return SnapResult(value: proposedEnd, target: nil) }
        let thresholdSeconds = Double(snapThresholdPx / pxPerSecond)

        var best = proposedEnd
        var bestDist = Double.greatestFiniteMagnitude
        var bestTarget: Double? = nil

        func consider(_ candidate: Double) {
            let dist = abs(proposedEnd - candidate)
            if dist < bestDist {
                bestDist = dist
                best = candidate
                bestTarget = candidate
            }
        }

        // Snap to playhead / ruler ticks.
        consider(max(0, playheadSeconds))
        let minor = timeRulerMinorSpacingSeconds()
        if minor > 0 {
            consider((proposedEnd / minor).rounded() * minor)
        }

        // Snap to other clips' start/end (across all tracks).
        for track in project.timeline.tracks {
            for clip in track.clips where clip.id != trimmingClipId {
                consider(clip.timelineStartSeconds)
                consider(clip.timelineStartSeconds + clip.durationSeconds)
            }
        }

        if bestDist <= thresholdSeconds {
            return SnapResult(value: best, target: bestTarget)
        }
        return SnapResult(value: proposedEnd, target: nil)
    }

    private func timeRulerMinorSpacingSeconds() -> Double {
        let desiredMajorPx: CGFloat = 120
        let candidateSeconds: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200]
        var majorSpacing: Double = 5
        for s in candidateSeconds {
            if CGFloat(s) * pxPerSecond >= desiredMajorPx {
                majorSpacing = s
                break
            }
        }
        return majorSpacing / 5
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

        // Range selection band in ruler (if active)
        if let (a, b) = normalizedRange() {
            let x0 = laneX + CGFloat(a) * pxPerSecond
            let x1 = laneX + CGFloat(b) * pxPerSecond
            let left = min(x0, x1)
            let right = max(x0, x1)
            let w = max(1, right - left)
            let band = CGRect(x: left, y: rulerRect.minY, width: w, height: rulerRect.height)

            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.10).cgColor)
            ctx.fill(band)
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.50).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: band.minX + 0.5, y: rulerRect.minY))
            ctx.addLine(to: CGPoint(x: band.minX + 0.5, y: rulerRect.maxY))
            ctx.move(to: CGPoint(x: band.maxX - 0.5, y: rulerRect.minY))
            ctx.addLine(to: CGPoint(x: band.maxX - 0.5, y: rulerRect.maxY))
            ctx.strokePath()
        }

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

        // External drop preview line in ruler
        if let preview = externalDropPreviewSeconds {
            let x = laneX + CGFloat(max(0, preview)) * pxPerSecond
            if x >= visible.minX - 40, x <= visible.maxX + 40 {
                ctx.setStrokeColor(NSColor.selectedControlColor.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: rulerRect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rulerRect.maxY))
                ctx.strokePath()
            }
        }

        // Snap guide line in ruler (if active)
        if let snap = snapGuideSeconds {
            let x = laneX + CGFloat(max(0, snap)) * pxPerSecond
            if x >= visible.minX - 40, x <= visible.maxX + 40 {
                ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.85).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: rulerRect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rulerRect.maxY))
                ctx.strokePath()
            }
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
