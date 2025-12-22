<p align="center">
  <img src="AppResources/AppIcon-Timeline.svg" width="128" height="128" alt="Yunqi" />
</p>

<h1 align="center">云起（Yunqi）</h1>

<p align="center">
  面向 <b>Apple Silicon</b> 优化的 macOS 视频剪辑工具：专注“顺滑预览 + 高效时间线编辑”。
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
  <a href="https://github.com/ChenyuHeee/Yunqi/releases"><img alt="Download" src="https://img.shields.io/badge/下载-Releases-181717?style=for-the-badge&logo=github" /></a>
</p>

---

## 截图

> 你可以把截图放到 `docs/` 或 `assets/`，然后把链接补到这里。

## 亮点

- **真实预览**：基于 AVFoundation 的播放与抽帧显示，能跟随时间线变更即时更新。
- **时间线编辑**：拖拽移动、边缘 Trim、吸附对齐；支持 Final Cut 风格的 Blade / Blade All。
- **撤销/重做**：编辑动作可回退、可恢复，适合快速试错。
- **快捷键友好**：J/K/L 播放控制、逐帧、循环等。

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

- 测试：`swift test`
- 设计与模块说明： [docs/prepare.md](docs/prepare.md)

