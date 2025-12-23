# Yunqi 长期路线图（完整功能版，Apple Silicon 优先）

本文从“长期完整开发”的角度，把 Yunqi 的目标能力拆成可持续演进的里程碑，并明确哪些底层系统必须先做对，避免未来功能越多越难改。

> 设计目标：**预览与导出同一真相**（Engine 输出的 RenderGraph/AudioGraph），并围绕 Apple Silicon 的硬编解码与 GPU 合成建立性能护城河。

## 0. 不可妥协的工程约束（越早定越省命）

- **单一真相**：时间线在任意时刻的“应该看到什么/听到什么”，必须由 `TimelineEvaluator -> (RenderGraph, AudioGraph)` 给出。UI 只消费结果，不拼装业务逻辑。
- **可复现与可测试**：Engine 输出必须 deterministic（同输入同输出）；为关键场景提供“黄金测试”（golden tests）。
- **文件格式可进化**：工程文件必须带 `schemaVersion`，并提供迁移策略（向后兼容或升级迁移）。
- **缓存必须可计算**：缩略图/波形/代理/预渲染缓存全部由 key 驱动（asset fingerprint + 参数），并能精确失效。
- **导出是队列系统**：导出永远是后台任务：可取消、可恢复、可重试、可观察（进度/日志）。
- **Apple Silicon 性能预算**：实时预览为第一优先级；允许“播放质量降级”，但不允许 UI 卡死。

## 1. 最终形态能力清单（按子系统）

### 1.1 工程与媒体（Project / Media）
- 工程：新建/打开/自动保存/崩溃恢复/版本快照
- 媒体库：导入、去重（fingerprint）、元数据分析（帧率/色彩/声道）
- 缩略图缓存、音频波形缓存
- 代理系统：后台生成/切换/清理/重建

### 1.2 时间线编辑（Timeline）
- 多轨：视频/音频/字幕/调整轨（adjustment layer）
- 基础编辑：split、trim、slip/slide、ripple delete、吸附、对齐
- 关键帧：变换/不透明度/滤镜参数（插值曲线）
- 速度：匀速（先）、变速曲线（后）
- 选择/多选/组（group）/锁定/静音/solo

### 1.3 渲染与预览（Render / Playback）
- Metal 合成：多层叠加、变换、基础滤镜、基础转场
- 色彩：至少 SDR P3；为 HDR（HLG/PQ）预留管线（后续再上）
- 实时调度：预取、丢帧策略、音画同步
- 质量档位：`realtime` 与 `high`（暂停/导出）

### 1.4 字幕与标题（Titles / Subtitles）
- 字幕轨：手动编辑 + SRT 导入/导出
- 标题模板：描边/阴影/背景条，关键帧动效（后续）

### 1.5 音频（Audio）
- 音量/淡入淡出
- 基础 EQ（可后置）
- 混音参数进入 `AudioGraph`，与视频同一评估器驱动

### 1.6 导出与交付（Export / Delivery）
- 预设：H.264/H.265/ProRes（逐步），分辨率/码率/帧率
- 队列：落盘恢复、取消、重试、历史裁剪、错误可诊断
- 片段导出、仅音频导出（后续）

## 2. 里程碑（建议顺序：先底座再花活）

### Milestone 1：编辑核心稳态（已在推进中）
验收标准：
- Engine 输出 deterministic，测试覆盖关键编辑场景
- Undo/Redo 覆盖所有编辑命令

### Milestone 2：缓存与代理（提升体验与性能）
- 缩略图/波形缓存 key 体系落地
- 代理后台生成（可中断/可恢复），预览可切换代理

### Milestone 3：Metal 预览替换（Phase 2）
- 解码 `CVPixelBuffer` -> `MTLTexture` -> RenderGraph 合成 -> 显示
- realtime 质量策略与降级（分辨率/跳过高成本效果）

#### 对齐 Final Cut Pro 的 Viewer 语义（作为 Phase 2 的“产品级定义”）

- **工程画布（Sequence/Project Format）是稳定参照**：Viewer 显示的是项目画布（`renderSize`），而不是“窗口多大就多大”。
- **默认 Fit（完整显示 + 黑边）**：窗口比例变化不会导致内容“漂移/感觉位置怪”。
- **Automatic Settings**：新项目默认 `formatPolicy=automatic`；在第一次有“有效视频内容”后，项目画布应锁定为该内容的显示分辨率（后续可提供手动改格式的 custom 路径）。
- **Spatial Conform（素材进画布的规则）**：至少支持 `fit` / `fill` / `none`（后续再做每个 clip 可配置）。
- **Viewer 缩放与像素语义**：支持 Fit / 100% / 200% 等离散档位（让“像素对齐”的体验可控），并在暂停/逐帧时默认走 high 质量。

#### Apple Silicon 优先的性能取向（建议作为 Phase 2/3 的硬约束）

- 目标：在 M 系列上把“预览流畅度、功耗、热量”当作一等公民，同时不牺牲未来特效/字幕/调色/代理的可演进性。
- 原则：
	- 预览尽量保持在 GPU（Metal）域内：避免 `CGImage` 往返与 CPU 侧像素搬运。
	- 充分利用统一内存与硬件媒体模块：硬件解码/编码优先，减少不必要的 copy。
	- 先建立“质量档位（realtime/high）”与降级策略，再做更激进的驱动/管线替换，避免未来返工。
- 质量档位：
	- realtime：播放时优先帧率与交互，允许分辨率/采样率等降级。
	- high：暂停/逐帧/导出前预览时优先画质，允许更高成本。
- 近期可执行的增量优化：
	- `CVMetalTextureCache`：把 `CVPixelBuffer` 直接映射为 `MTLTexture`（替代/补强 `CIContext.render`），减少中间态与 copy。
	- 硬件解码优先：引入 `VTDecompressionSession` 驱动解码（或确保 AVFoundation 路径可稳定落到硬件），输出 `CVPixelBuffer` 直接喂给 Metal。
	- 显示与缩放：优先用 GPU 做缩放；若引入 upscaling，可评估 MetalFX（在可用平台上）以提升高倍率缩放观感。
	- 纹理/缓冲池化：统一管理中间纹理与临时 buffer，降低分配抖动。
	- 常用效果 GPU 化：缩放/裁剪/基础调色/叠字等走 Metal shader，避免 CPU 介入。
	- 编码侧策略层：导出优先硬件编码路径（VideoToolbox/AVAssetWriter 硬件能力），并为“快速/高质量”提供可扩展策略位。

### Milestone 4：导出走单一真相（Phase 3 / B3）
- 使用 `AVAssetWriter` 以“帧序列”方式编码封装
- 导出逐帧消费 Engine+RenderGraph（与预览一致）
- 保留队列系统能力：取消/恢复/重试/日志

### Milestone 5：字幕/特效/调色扩展
- 字幕轨（SRT）与基础标题
- 高频特效 + 高频转场
- 基础调色参数（曝光/对比/饱和）

## 3. B3（导出）推荐的最小切入点

为了不一次性推翻现有导出：
- 第一步：先把导出“执行器”抽象出来（ExportRenderer/ExportEncoder），让队列不关心具体实现。
- 第二步：新增一条 `AVAssetWriter` 路径，先做 **视频单轨/无特效** 的可用导出（仍由 Engine 给出取帧时间）。
- 第三步：逐步把多轨合成/字幕/特效接到 RenderGraph 里，并用同一渲染器导出。

## 4. 需要你拍板的 3 个取舍（否则路线图会分叉）

1) 首发目标：更接近“轻量剪映”还是“接近 Final Cut 的多轨专业”？
2) HDR：首发只做 SDR，还是必须上 HDR（HLG/PQ）？
3) 时间线交互：时间线是否允许引入 AppKit/NSView（更强拖拽与性能）？
