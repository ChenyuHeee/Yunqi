import AVFoundation
import EditorCore
import Foundation

/// 导出执行器：把“队列/持久化/状态机”与“具体导出实现”解耦。
///
/// 设计目标：
/// - 保持队列逻辑稳定：未来切换 `AVAssetWriter` 或 RenderGraph 导出时，不需要推倒重来。
/// - 取消语义统一：上层取消（Task cancellation）必须能贯通到底层实现（session.cancelExport / writer finish）。
@MainActor
protocol ExportExecutor {
    func export(
        job: ExportJob,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// 过渡实现：复用现有 `AVAssetExportSession` 管线（PreviewPlayerController 内）。
@MainActor
final class AVAssetExportSessionExecutor: ExportExecutor {
    func export(
        job: ExportJob,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // 保持与旧实现一致：每次导出创建独立 controller，避免跨任务共享状态。
        let controller = PreviewPlayerController()
        try await controller.export(
            project: job.project,
            to: job.outputURL,
            presetName: job.presetName,
            fileType: job.fileType,
            onProgress: onProgress
        )
    }
}
