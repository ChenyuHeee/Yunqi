# Changelog

## v0.4.0 (2025-12-22)

第四个测试版本：对齐 Final Cut 的 Blade 语义，并完成 macOS App 形态的本地化（含系统菜单）与图标集成。

### Highlights
- Blade / Blade All：⌘B（优先切所选片段；无选择时切 playhead 命中片段），⇧⌘B（全轨切刀）；一次操作一次 Undo/Redo
- 本地化（中/英）：菜单与主要 UI 文案补齐；简体中文系统下可正确显示中文系统菜单
- App 名称与图标：中文显示“云起”；集成 App Icon（SVG → icns）并打进 `.app`
- 文档展示：README 增加 logo、badges、Insights 图表卡片

### Notes
- 仍为测试版：导出与素材兼容性、性能与稳定性会继续迭代。

### 安装与运行
- 这是未签名/未公证的测试构建，macOS 可能提示“无法验证开发者”。
- 下载 Release 里的 `Yunqi-<tag>-macos.zip`，解压后打开 `YunqiMacApp.app`（或在终端执行 `open YunqiMacApp.app`）。

## v0.3.0 (2025-12-21)

第三个测试版本：继续对齐 NLE（Final Cut）手感，新增范围选择与范围波纹删除。

### Highlights
- Range Selection：R 切换范围工具；拖拽设置范围；I/O 设 In/Out；X 清除范围
- Ripple Delete Range：在无 clip 选中时 Delete 可对范围执行一次 Undo 的波纹删除
- Snapping 体验补齐：N 切换吸附开关；Option 临时关闭；吸附提示线覆盖标尺与时间线
- 菜单补齐：新增 Range 菜单（Set In/Out、Clear、Ripple Delete Range）

### Notes
- 仍为测试版：导出与素材兼容性、性能与稳定性会继续迭代。

### 安装与运行
- 这是未签名/未公证的测试构建，macOS 可能提示“无法验证开发者”。
- 下载 Release 里的 `Yunqi-<tag>-macos.zip`，解压后在终端运行：`./YunqiMacApp`

## v0.2.0 (2025-12-21)

第二个测试版本，补齐高频剪辑交互与多工程工作流。

### Highlights
- 时间线编辑增强：多选/框选、批量移动/删除（一次 Undo/Redo）、Trim 体验完善
- Ripple Delete：默认 Delete 波纹删除，Shift+Delete 普通删除（保留空隙）
- 时间线导航：Home/End 到首尾、Shift+滚轮水平滚动、双击空白回播放头
- 视觉辅助：视频 clip 迷你缩略图、音频 clip 波形（异步缓存，滚动可见范围按需生成）
- 系统窗口 tab bar 多文档：New/Open 可配置在“当前标签 / 新标签 / 新窗口”打开；关闭未保存提示
- 工程初始化：新建工程默认自带一条 video track（macOS App 与 CLI init 一致）

### Notes
- 仍为测试版：导出与素材兼容性、性能与稳定性会继续迭代。

### 安装与运行
- 这是未签名/未公证的测试构建，macOS 可能提示“无法验证开发者”。
- 下载 Release 里的 `Yunqi-<tag>-macos.zip`，解压后在终端运行：`./YunqiMacApp`

## v0.1.0-test.1 (2025-12-21)

首个对外测试版本。

### Highlights
- macOS 剪辑 UI：媒体导入、素材列表、视频轨与时间线
- 时间线编辑：拖拽移动、Trim（左右边缘拖拽）、吸附对齐、Undo/Redo
- 真实预览：AVFoundation 播放/抽帧显示，随工程变更自动重建
- 播放控制：scrub、逐帧、J/K/L、循环播放
- 导出（MVP）：导出 `.mp4`（H.264，系统 preset），含进度提示

### Notes
- 这是测试版：可能存在崩溃、兼容性、性能问题；欢迎提 Issue 反馈。

### 安装与运行
- 这是未签名/未公证的测试构建，macOS 可能提示“无法验证开发者”。
- 下载 Release 里的 `Yunqi-<tag>-macos.zip`，解压后在终端运行：`./YunqiMacApp`

### 已知问题
- 首测版主要验证剪辑与预览闭环，导出与复杂素材兼容性仍在完善。
- 反向播放（J，负速率）在部分素材/系统组合上可能不生效。

### 反馈
- 建议在 GitHub Issues 里反馈，并附：素材格式信息、复现步骤、以及崩溃日志（如有）。
