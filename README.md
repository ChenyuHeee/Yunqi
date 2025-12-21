# 云起（Yunqi）

面向 **Apple Silicon** 优化的 macOS 视频剪辑工具：专注“顺滑预览 + 高效时间线编辑”，让剪辑更轻、更快、更直觉。

- English: [README.en.md](README.en.md)
- 更新记录： [CHANGELOG.md](CHANGELOG.md)

---

## 亮点

- **真实预览**：基于 AVFoundation 的播放与抽帧显示，能跟随时间线变更即时更新。
- **时间线交互**：拖拽移动、左右边缘拖拽 Trim、吸附对齐，操作明确。
- **撤销/重做**：编辑动作可回退、可恢复，适合快速试错。
- **快捷键与播放控制**：支持 scrub 定位、逐帧前进/后退、J/K/L 播放控制、循环播放。
- **工程化结构**：编辑核心与 UI 分层，多模块 SwiftPM 工程，便于持续迭代。

## 当前能力（MVP）

- 导入媒体（本地文件）并加入视频轨
- 时间线：移动/Trim/吸附
- 预览：播放、暂停、停止、scrub、逐帧、循环

## 运行（macOS App）

需要 macOS 13+，Swift 6。

- 构建：`swift build --product YunqiMacApp`
- 启动（推荐）：`./run-macapp.sh`

## 开发

- 测试：`swift test`
- 项目设计与模块说明可参考：[/docs/prepare.md](docs/prepare.md)

