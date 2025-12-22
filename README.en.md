<p align="center">
	<img src="AppResources/AppIcon-Timeline.svg" width="128" height="128" alt="Yunqi" />
</p>

<h1 align="center">Yunqi</h1>

<p align="center">
	A macOS video editor optimized for <b>Apple Silicon</b> — focused on smooth preview playback and efficient timeline editing.
</p>

<p align="center">
	<a href="https://github.com/ChenyuHeee/Yunqi/releases"><img alt="GitHub release" src="https://img.shields.io/github/v/release/ChenyuHeee/Yunqi" /></a>
	<a href="https://github.com/ChenyuHeee/Yunqi/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/github/license/ChenyuHeee/Yunqi" /></a>
	<a href="https://github.com/ChenyuHeee/Yunqi/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/ChenyuHeee/Yunqi" /></a>
	<a href="https://github.com/ChenyuHeee/Yunqi/issues"><img alt="Issues" src="https://img.shields.io/github/issues/ChenyuHeee/Yunqi" /></a>
	<a href="https://github.com/ChenyuHeee/Yunqi/commits/main"><img alt="Last commit" src="https://img.shields.io/github/last-commit/ChenyuHeee/Yunqi" /></a>
</p>

<p align="center">
	<a href="README.md"><img alt="Chinese" src="https://img.shields.io/badge/中文-README-181717?style=for-the-badge&logo=readme" /></a>
	<a href="CHANGELOG.md"><img alt="Changelog" src="https://img.shields.io/badge/Changelog-CHANGELOG-181717?style=for-the-badge&logo=github" /></a>
	<a href="https://github.com/ChenyuHeee/Yunqi/releases/latest"><img alt="Downloads" src="https://img.shields.io/badge/Download-Latest%20Release-181717?style=for-the-badge&logo=github" /></a>
</p>

---

## Screenshots

> Add screenshots under `docs/` or `assets/` and link them here.

## Highlights

- **Real preview**: AVFoundation-based playback + frame extraction, rebuilt when the timeline changes.
- **Timeline editing**: move clips, trim by dragging edges, snapping for alignment.
- **Undo/Redo**: safe iteration with reversible edits.
- **Keyboard-first**: J/K/L playback, frame stepping, loop, etc.

## Shortcuts (common)

> Some shortcuts require timeline focus (click the timeline once).

- Play/Pause: Space
- Toggle Loop: ⌘L
- Step frame: ← / → (or , / .)
- Blade: ⌘B
- Blade All: ⇧⌘B
- Ripple Delete: Delete

## Run locally (for developers)

Requires macOS 13+ and Swift 6.

- Build: `swift build --product YunqiMacApp`
- Launch (recommended): `./run-macapp.sh`

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

### Contributors

[![Contributors](https://contrib.rocks/image?repo=ChenyuHeee/Yunqi)](https://github.com/ChenyuHeee/Yunqi/graphs/contributors)

## Contributing

- Report bugs / feature requests: <https://github.com/ChenyuHeee/Yunqi/issues>
- Pull requests: <https://github.com/ChenyuHeee/Yunqi/pulls>

## Developer notes

- Tests: `swift test`
- Design notes: [docs/prepare.md](docs/prepare.md)
