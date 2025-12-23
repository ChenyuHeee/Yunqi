import AVFoundation
import EditorCore
import Foundation

/// 导出任务（B1：内存队列）。
///
/// 设计目标：
/// - `Codable`：未来可直接落盘恢复
/// - 捕获 enqueue 时刻的 `Project` 快照，避免导出过程中工程继续被编辑导致不一致
struct ExportJob: Codable, Sendable {
    var id: UUID
    var createdAt: Date

    /// 捕获 enqueue 时刻的工程快照（B2 可改为引用 projectURL + fingerprint）。
    var project: Project

    var outputURL: URL
    var presetName: String
    var fileTypeIdentifier: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        project: Project,
        outputURL: URL,
        presetName: String = AVAssetExportPresetHighestQuality,
        fileTypeIdentifier: String = AVFileType.mp4.rawValue
    ) {
        self.id = id
        self.createdAt = createdAt
        self.project = project
        self.outputURL = outputURL
        self.presetName = presetName
        self.fileTypeIdentifier = fileTypeIdentifier
    }

    var fileType: AVFileType {
        AVFileType(fileTypeIdentifier)
    }
}

enum ExportJobState: Sendable, Equatable {
    case queued
    case running(progress: Double)
    case completed
    case failed(message: String)
    case cancelled
}

private enum ExportQueuePersistence {
    static let version: Int = 1

    enum PersistedState: Codable, Sendable {
        case queued
        case running
        case completed
        case failed(message: String)
        case cancelled
    }

    struct PersistedItem: Codable, Sendable {
        var job: ExportJob
        var state: PersistedState
    }

    struct PersistedQueue: Codable, Sendable {
        var version: Int
        var items: [PersistedItem]
    }

    static func storageURL() throws -> URL {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        // NOTE: keep it simple; no bundle ID required for SwiftPM app.
        let dir = base
            .appendingPathComponent("Yunqi", isDirectory: true)
            .appendingPathComponent("ExportQueue", isDirectory: true)

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json", isDirectory: false)
    }

    static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}

/// 单进程串行的内存导出队列。
///
/// 说明：
/// - B1 先串行（并行会带来更多资源竞争、热量/功耗与复杂度）
/// - 未来 B2 加持久化；B3 可加并行上限
@MainActor
final class ExportQueue {
    struct Item: Sendable {
        var job: ExportJob
        var state: ExportJobState
    }

    private let executor: any ExportExecutor

    private(set) var items: [Item] = []

    private var runningTask: Task<Void, Never>?
    private var runningJobId: UUID?
    private var cancelIds: Set<UUID> = []

    private enum HistoryPolicy {
        static let maxKeptFailed: Int = 20
        static let maxKeptCompletedOrCancelled: Int = 50
    }

    init(executor: any ExportExecutor = AVAssetExportSessionExecutor()) {
        self.executor = executor
        restoreFromDiskIfPossible()
        pruneHistoryIfNeeded()
        persistToDiskBestEffort()
        runIfNeeded()
    }

    /// enqueue 并自动触发执行。
    func enqueue(_ job: ExportJob) {
        items.append(Item(job: job, state: .queued))
        pruneHistoryIfNeeded()
        persistToDiskBestEffort()
        runIfNeeded()
    }

    func cancel(jobId: UUID) {
        cancelIds.insert(jobId)

        if runningJobId == jobId {
            runningTask?.cancel()
        }

        // If queued: mark cancelled immediately.
        if let idx = items.firstIndex(where: { $0.job.id == jobId }) {
            switch items[idx].state {
            case .queued:
                items[idx].state = .cancelled
                pruneHistoryIfNeeded()
                persistToDiskBestEffort()
            default:
                break
            }
        }
    }

    var isRunning: Bool {
        items.contains { if case .running = $0.state { return true } else { return false } }
    }

    var hasQueued: Bool {
        items.contains { if case .queued = $0.state { return true } else { return false } }
    }

    /// 当前活跃任务进度（无则为 nil）。
    var currentProgress: Double? {
        for item in items {
            if case let .running(progress) = item.state { return progress }
        }
        return nil
    }

    private func runIfNeeded() {
        guard runningTask == nil else { return }

        guard let idx = items.firstIndex(where: { if case .queued = $0.state { return true } else { return false } }) else {
            return
        }

        let jobId = items[idx].job.id
        runningJobId = jobId
        if cancelIds.contains(jobId) {
            items[idx].state = .cancelled
            cancelIds.remove(jobId)
            runningJobId = nil
            pruneHistoryIfNeeded()
            persistToDiskBestEffort()
            runIfNeeded()
            return
        }

        items[idx].state = .running(progress: 0)
        persistToDiskBestEffort()

        runningTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.runningTask = nil
                    self.runningJobId = nil
                    self.runIfNeeded()
                }
            }

            do {
                try await self.performExport(job: self.items[idx].job) { p in
                    Task { @MainActor in
                        guard let current = self.items.firstIndex(where: { $0.job.id == jobId }) else { return }
                        if self.cancelIds.contains(jobId) {
                            return
                        }
                        self.items[current].state = .running(progress: max(0, min(1, p)))
                    }
                }

                await MainActor.run {
                    guard let current = self.items.firstIndex(where: { $0.job.id == jobId }) else { return }
                    if self.cancelIds.contains(jobId) {
                        self.items[current].state = .cancelled
                        self.cancelIds.remove(jobId)
                    } else {
                        self.items[current].state = .completed
                    }
                    self.pruneHistoryIfNeeded()
                    self.persistToDiskBestEffort()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let current = self.items.firstIndex(where: { $0.job.id == jobId }) else { return }
                    self.items[current].state = .cancelled
                    self.cancelIds.remove(jobId)
                    self.pruneHistoryIfNeeded()
                    self.persistToDiskBestEffort()
                }
            } catch {
                await MainActor.run {
                    guard let current = self.items.firstIndex(where: { $0.job.id == jobId }) else { return }
                    if self.cancelIds.contains(jobId) {
                        self.items[current].state = .cancelled
                        self.cancelIds.remove(jobId)
                    } else {
                        self.items[current].state = .failed(message: error.localizedDescription)
                    }
                    self.pruneHistoryIfNeeded()
                    self.persistToDiskBestEffort()
                }
            }
        }
    }

    private func pruneHistoryIfNeeded() {
        // Never prune active jobs; only prune finished history to keep the persisted file bounded.
        let activeIds: Set<UUID> = Set(
            items.compactMap { item in
                switch item.state {
                case .queued, .running:
                    return item.job.id
                case .completed, .failed, .cancelled:
                    return nil
                }
            }
        )

        let failed = items
            .filter { item in
                if case .failed = item.state { return true }
                return false
            }
            .sorted { $0.job.createdAt > $1.job.createdAt }
            .prefix(HistoryPolicy.maxKeptFailed)

        let completedOrCancelled = items
            .filter { item in
                switch item.state {
                case .completed, .cancelled:
                    return true
                case .queued, .running, .failed:
                    return false
                }
            }
            .sorted { $0.job.createdAt > $1.job.createdAt }
            .prefix(HistoryPolicy.maxKeptCompletedOrCancelled)

        var keepIds = activeIds
        for item in failed { keepIds.insert(item.job.id) }
        for item in completedOrCancelled { keepIds.insert(item.job.id) }

        // Preserve original ordering for determinism (and to keep queued order stable).
        items = items.filter { keepIds.contains($0.job.id) }
    }

    private func restoreFromDiskIfPossible() {
        do {
            let url = try ExportQueuePersistence.storageURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }

            let data = try Data(contentsOf: url)
            let decoded = try ExportQueuePersistence.makeDecoder().decode(ExportQueuePersistence.PersistedQueue.self, from: data)
            guard decoded.version == ExportQueuePersistence.version else {
                NSLog("[ExportQueue] Unsupported persisted version: %d", decoded.version)
                return
            }

            self.items = decoded.items.map { persisted in
                let state: ExportJobState
                switch persisted.state {
                case .queued:
                    state = .queued
                case .running:
                    // Previous app quit while exporting; mark as failed (user can retry).
                    state = .failed(message: "Export interrupted (app quit)")
                case .completed:
                    state = .completed
                case let .failed(message):
                    state = .failed(message: message)
                case .cancelled:
                    state = .cancelled
                }
                return Item(job: persisted.job, state: state)
            }

            // If we converted any running->failed, persist the normalization.
            if decoded.items.contains(where: { if case .running = $0.state { return true } else { return false } }) {
                persistToDiskBestEffort()
            }
        } catch {
            NSLog("[ExportQueue] Failed to restore persisted queue: %@", String(describing: error))
        }
    }

    private func persistToDiskBestEffort() {
        do {
            pruneHistoryIfNeeded()
            let url = try ExportQueuePersistence.storageURL()
            let snapshot = ExportQueuePersistence.PersistedQueue(
                version: ExportQueuePersistence.version,
                items: items.map { item in
                    let state: ExportQueuePersistence.PersistedState
                    switch item.state {
                    case .queued:
                        state = .queued
                    case .running:
                        // Do not persist progress; only persist that it's running.
                        state = .running
                    case .completed:
                        state = .completed
                    case let .failed(message):
                        state = .failed(message: message)
                    case .cancelled:
                        state = .cancelled
                    }
                    return ExportQueuePersistence.PersistedItem(job: item.job, state: state)
                }
            )

            let data = try ExportQueuePersistence.makeEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("[ExportQueue] Failed to persist queue: %@", String(describing: error))
        }
    }

    private func performExport(
        job: ExportJob,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await executor.export(job: job, onProgress: onProgress)
    }
}
