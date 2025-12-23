# Yunqi 架构骨架（从 prepare.md 落地）

另见：`docs/rebuild.md`（重建规划：Apple Silicon 优先、目标架构与迁移路径）。

## 分层
- UI/App：交互与窗口、状态展示（可先保留 AVFoundation 预览作为过渡）
- UIBridge：SwiftUI 友好的 Store（把 Engine 映射成 ObservableObject）
- EditorEngine：播放调度 + 时间线评估（Engine）+ UI 门面（EditorSession）
- EditorCore：工程模型、命令系统（Undo/Redo）、时间线结构（不依赖渲染/播放实现）
- RenderEngine：渲染请求/质量档位/帧输出抽象（后续接 Metal）
- MediaIO：素材导入/分析抽象（后续接 AVFoundation/VideoToolbox）
- Storage：工程文件读写、缓存目录约定（先做 JSON）

## 目标
- 先保证：模块边界清晰 + 可编译 + 可测试
- 后续迭代：把播放调度、缓存、Metal 合成、硬编导出逐步填充

## 依赖方向（长期）
- `EditorCore` 不依赖 `RenderEngine`/`AVFoundation`
- `EditorEngine` 依赖 `EditorCore` + `RenderEngine`
- `UIBridge` 依赖 `EditorEngine`（并可按需依赖 `EditorCore` 类型）
