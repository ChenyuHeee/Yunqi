# Yunqi 架构骨架（从 prepare.md 落地）

## 分层
- UI/App：交互与窗口、状态展示
- EditorCore：工程模型、命令系统（Undo/Redo）、时间线结构
- EditorSession：UI 友好的门面（组合编辑与回放调度）
- RenderEngine：渲染请求/质量档位/帧输出抽象（后续接 Metal）
- MediaIO：素材导入/分析抽象（后续接 AVFoundation/VideoToolbox）
- Storage：工程文件读写、缓存目录约定（先做 JSON）

## 目标
- 先保证：模块边界清晰 + 可编译 + 可测试
- 后续迭代：把播放调度、缓存、Metal 合成、硬编导出逐步填充
