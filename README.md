<p align="center">
  <img src="AppResources/AppIcon-Timeline.svg" width="128" height="128" alt="Yunqi" />
</p>

<h1 align="center">云起（Yunqi）</h1>

<p align="center">
  面向 <b>Apple Silicon</b> 优化的 macOS 视频剪辑工具：专注「顺滑预览 × 高效时间线编辑」。
</p>

<p align="center">
  <a href="https://github.com/ChenyuHeee/Yunqi/releases"><img alt="GitHub release" src="https://img.shields.io/github/v/release/ChenyuHeee/Yunqi" /></a>
  <a href="https://github.com/ChenyuHeee/Yunqi/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/github/license/ChenyuHeee/Yunqi" /></a>
  <a href="https://github.com/ChenyuHeee/Yunqi/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/ChenyuHeee/Yunqi" /></a>
  <a href="https://github.com/ChenyuHeee/Yunqi/issues"><img alt="Issues" src="https://img.shields.io/github/issues/ChenyuHeee/Yunqi" /></a>
  <a href="https://github.com/ChenyuHeee/Yunqi/commits/main"><img alt="Last commit" src="https://img.shields.io/github/last-commit/ChenyuHeee/Yunqi" /></a>
</p>

<p align="center">
  <a href="README.en.md"><img alt="English" src="https://img.shields.io/badge/English-README-181717?style=for-the-badge&logo=readme" /></a>
  <a href="CHANGELOG.md"><img alt="Changelog" src="https://img.shields.io/badge/更新记录-CHANGELOG-181717?style=for-the-badge&logo=github" /></a>
  <a href="https://github.com/ChenyuHeee/Yunqi/releases/latest"><img alt="Download" src="https://img.shields.io/badge/下载-Latest%20Release-181717?style=for-the-badge&logo=github" /></a>
</p>

---

## 一句话

如果你在找一个**更贴近“剪辑手感”**的 macOS 编辑器：Yunqi 把“预览链路”和“时间线编辑”当作第一优先级来做，并围绕 Apple Silicon 的图形与音频能力持续优化。

> 这是一个仍在快速迭代中的项目：欢迎试用、提 Issue、或直接上车贡献。

## 适合谁

- 想要一个 **原生 macOS**、偏专业剪辑交互的编辑器（而不是网页/跨端壳）。
- 对 **预览是否顺滑**、**时间线操作是否稳定可预期** 比“功能堆叠”更在意。
- 对音频/渲染的工程质量有要求：希望关键链路**可测试、可回归、可确定性复现**。

## 截图 / 演示

> 建议把截图/GIF 放到 `docs/` 或 `assets/`，然后把链接补到这里。

- （占位）主界面 + 时间线
- （占位）预览窗口（Metal）
- （占位）Blade / Ripple Delete 演示

## 核心能力

- **时间线编辑**：拖拽移动、边缘 Trim、吸附对齐；支持 Final Cut 风格的 Blade / Blade All。
- **撤销/重做**：编辑动作可回退、可恢复（适合快速试错）。
- **预览链路（Apple Silicon 优先）**：以 Metal 为优先路径，尽量减少非必要回退。
- **音频确定性底座**：48k sample clock、稳定 key/哈希、稳定 JSON dump、可回归的 golden 框架。
- **缓存体系（可失效/可重建）**：波形多分辨率 mip 持久化、PCM 分段缓存；素材变更通过 fingerprint 避免误复用。

## 为什么值得关注（给“路人/评审/未来的你”）

- **工程可信**：关键链路有单元测试与回归测试（`swift test`）兜底。
- **确定性优先**：同输入、同配置应输出一致——方便定位问题、做性能对比、做长期演进。
- **Apple Silicon 友好**：在能吃到收益的地方优先走 Metal / Accelerate 思路。

> 想看更详细的设计与模块说明：见 [docs/prepare.md](docs/prepare.md)

## 下载与体验（用户）

- 直接下载：<https://github.com/ChenyuHeee/Yunqi/releases/latest>
- 如果你更想从源码跑起来：见下方“本地运行（开发者）”。

## 快捷键（常用）

> 部分按键需要“时间线获得焦点”（点一下时间线区域即可）。

- 播放/暂停：Space
- 循环开关：⌘L
- 逐帧：← / →（或 , / .）
- 切刀（Blade）：⌘B
- 全轨切刀（Blade All）：⇧⌘B
- 删除（Ripple Delete）：Delete

## 本地运行（开发者）

需要 macOS 13+、Swift 6。

- 构建：`swift build --product YunqiMacApp`
- 启动（推荐）：`./run-macapp.sh`
- 测试（推荐先跑）：`swift test`

## 路线图

- 音频与渲染相关的推进清单：`docs/audio-todolist.md`
- Bug / 需求：<https://github.com/ChenyuHeee/Yunqi/issues>

## GitHub Insights

<p>
  <a href="https://github.com/ChenyuHeee/Yunqi/pulse"><img alt="Pulse" src="https://img.shields.io/badge/Insights-Pulse-181717?style=for-the-badge&logo=github" /></a>
  <a href="https://github.com/ChenyuHeee/Yunqi/activity"><img alt="Activity" src="https://img.shields.io/badge/Insights-Activity-181717?style=for-the-badge&logo=github" /></a>
  <a href="https://github.com/ChenyuHeee/Yunqi/graphs/contributors"><img alt="Contributors" src="https://img.shields.io/badge/Insights-Contributors-181717?style=for-the-badge&logo=github" /></a>
  <a href="https://github.com/ChenyuHeee/Yunqi/issues"><img alt="Issues" src="https://img.shields.io/badge/Track-Issues-181717?style=for-the-badge&logo=github" /></a>
  <a href="https://github.com/ChenyuHeee/Yunqi/pulls"><img alt="Pull requests" src="https://img.shields.io/badge/Contribute-PRs-181717?style=for-the-badge&logo=github" /></a>
</p>

### Repo Cards

[![Repo](https://github-readme-stats.vercel.app/api/pin/?username=ChenyuHeee&repo=Yunqi)](https://github.com/ChenyuHeee/Yunqi)

[![Top Langs](https://github-readme-stats.vercel.app/api/top-langs/?username=ChenyuHeee&repo=Yunqi&layout=compact)](https://github.com/ChenyuHeee/Yunqi)

### Star History

[![Star History Chart](https://api.star-history.com/svg?repos=ChenyuHeee/Yunqi&type=Date)](https://star-history.com/#ChenyuHeee/Yunqi&Date)

### 贡献者

[![Contributors](https://contrib.rocks/image?repo=ChenyuHeee/Yunqi)](https://github.com/ChenyuHeee/Yunqi/graphs/contributors)

## 参与贡献

- 提 Bug / 提需求：<https://github.com/ChenyuHeee/Yunqi/issues>
- 提交 PR：<https://github.com/ChenyuHeee/Yunqi/pulls>

## 开发备注

- 设计与模块说明： [docs/prepare.md](docs/prepare.md)

