# Yunqi 重建规划（Apple Silicon 优先）

本文件描述 Yunqi 的“长期可演进”目标架构与迁移路径，专门针对 Apple Silicon（M 系列）的视频剪辑场景：实时预览 + 离线导出 + 未来字幕/特效/调色/代理/队列。

如果你希望从“做最完整的功能、便于持续开发”的角度来推进，请同时阅读：`docs/roadmap.md`（长期功能版路线图与里程碑）。

## 为什么要动（当前风险）
- **双实现风险**：预览/导出主要依赖 AVFoundation（`AVPlayerItem`/`AVMutableComposition`/`AVVideoComposition`），同时代码里已有另一套 `RenderEngine + PlaybackController` 的骨架；未来一旦加入字幕/特效/调色，很容易出现“预览一套、导出一套”，效果不一致且维护成本指数级上升。
- **依赖方向不稳**：领域层（工程模型/编辑命令）不应依赖渲染层。目标是：Domain/Editor 独立于 AVFoundation/Metal/CI。
- **管线能力缺位**：代理/缓存/导出队列/色彩管理/关键帧，本质是管线型系统，应该放到架构中心，而不是散落在 UI 或 AVComposition 拼装逻辑里。

## 目标原则（Apple Silicon 优先）
- **单一真相**：同一套 Timeline 评估与同一套 RenderGraph 同时服务实时预览与离线导出。
- **零拷贝/少拷贝**：解码输出以 `CVPixelBuffer` 为核心，桥接到 `MTLTexture`（`CVMetalTextureCache`），减少 CPU<->GPU 往返。
- **分级质量**：`realtime`（播放）与 `high`（暂停/导出）走同一图但不同质量策略。
- **可缓存、可失效**：所有缓存（缩略图/波形/代理/预渲染）都必须由可计算的 key 驱动（fingerprint/hash），并且能精确失效。

## 目标分层（建议）
### 1) Domain（纯模型）
- `Project/Timeline/Track/Clip`、工程元信息、媒体引用等。
- 不依赖 AVFoundation / Metal / CoreImage。

### 2) Editor（编辑与撤销）
- 命令栈（Undo/Redo）只修改 Domain。
- 提供稳定的变更版本号/指纹，驱动缓存失效。

### 3) Engine（时间线评估器）
- 输入：`Project snapshot + playhead time`。
- 输出：某一时刻需要哪些源帧、哪些效果/字幕、以及音频混音参数。
- 产物以 `RenderGraph`（视频）与 `AudioGraph`（音频）表达。

### 4) Render（GPU 合成与特效）
- Metal 管线执行 `RenderGraph`。
- 内部建议线性工作空间，至少为 LUT/调色/HDR 预留格式能力。
- 资源池化（pixel buffer/texture）优先，避免每帧分配。

### 5) Playback（实时预览调度）
- 音画同步、预取、丢帧策略、自动降级（分辨率/跳过高成本效果/切代理）。
- 输出到 `CAMetalLayer/MTKView`（推荐）或其他显示层。

### 6) Export（离线渲染与队列）
- 与预览共用 Engine+RenderGraph，质量档位 `high`。
- 导出建议使用 `AVAssetWriter` 管理队列/取消/重试/分段；编码尽量走硬件路径。

### 7) Cache / Proxy（性能与体验护城河）
- 缩略图/波形：按 asset fingerprint + 时间范围 + 规格做 key。
- 代理：后台任务生成（规格可配置），可清理可重建。
- 预渲染缓存：按 RenderGraph hash + time 做 key（先粗粒度后细化）。

## 推荐模块边界（SwiftPM Targets）
- `EditorCore`：Domain + Editor（纯编辑核心，**不依赖** Render/AVFoundation）。
- `RenderEngine`：渲染抽象（后续接 Metal）。
- `EditorEngine`：`EditorSession`、播放调度、Engine 评估器（依赖 `EditorCore` + `RenderEngine`）。
- `UIBridge`：把 `EditorEngine` 映射成 SwiftUI 友好的 Store。
- `YunqiMacApp`：UI/App（可继续保留 AVFoundation 预览作为过渡实现）。

## 迁移路径（分阶段，避免推倒重来）
### Phase 0（本次动刀）：修正依赖方向
- 把 `PlaybackController/PlaybackState/EditorSession` 从 `EditorCore` 移出到 `EditorEngine`。
- 目标：`EditorCore` 不再依赖 `RenderEngine`。

### Phase 1：建立“唯一真相”Engine 输出
- 定义 `RenderGraph`/`AudioGraph` 的最小形态（先支持变换/叠加/简单字幕占位）。
- UI 与导出开始消费同一评估结果（可先在导出侧验证一致性）。

本仓库当前的 Phase 1 交付（最小形态）：
- `EditorEngine.RenderGraph`：描述“某一帧需要渲染的层”（当前先覆盖视频素材层与取样时间点）
- `EditorEngine.TimelineEvaluator`：将 `Project + timeSeconds` 评估成 `RenderGraph`

### Phase 2：Metal 实时预览替换 AVPlayer 预览
- 打通解码 pixel buffer -> metal texture -> 合成 -> 显示。
- 引入 realtime 质量策略与预取。

### Phase 3：导出切到同一图（消除双实现）
- 导出通过 Engine+RenderGraph 产出帧，再编码封装。
- 建立导出队列与失败重试。

## 导出队列（B1 现状）
当前先实现 **内存队列**，但 Job 结构按可持久化设计：
- `ExportJob` 为 `Codable`，并在 enqueue 时捕获 `Project` 快照，避免导出过程中工程继续被编辑导致结果不一致
- 队列串行执行（先保守稳定），后续再扩展并发上限与落盘恢复（B2）

配套 UI：
- “导出…” 会打开一个导出对话框（sheet），在同一处承载：导出位置选择、进度展示、以及“取消导出”按钮
- 取消会真正触发底层 `AVAssetExportSession.cancelExport()`（不只是 UI 状态标记）

队列清理策略（B1）：
- 仅对已完成/失败/取消的历史任务做上限裁剪，避免持久化文件无限增长（不会影响 queued/running 的任务）

### Phase 4：功能扩展
- 字幕（SRT/ASS）→ 关键帧 → 转场 → LUT/调色 → 代理 → 预设/产品化。

## 面向“长期完整功能”的落地方式

核心原则：先把“底座”做对，再加功能。否则功能越多，推翻成本越高。

底座优先级（从高到低）：
- Engine 单一真相（`TimelineEvaluator -> RenderGraph/AudioGraph`）可复现、可测试
- Cache/Proxy 以 key 驱动并能精确失效
- Export 以队列系统承载，并最终走同一真相（B3：AVAssetWriter + RenderGraph）

近期建议的下一步（在现有进度上）：
- Phase 2：Metal 预览替换 AVPlayer（先最小可用链路，再补质量策略与缓存）
- Phase 3 / B3：导出切到 AVAssetWriter，并逐步改为消费 Engine+RenderGraph（消除双实现）

