# Yunqi

A macOS video editor optimized for **Apple Silicon** — focused on smooth preview playback and efficient timeline editing.

- 中文版： [README.md](README.md)

---

## Highlights

- **Real preview**: AVFoundation-based playback + frame extraction, rebuilt when the timeline changes.
- **Timeline editing**: move clips, trim by dragging edges, snapping for alignment.
- **Undo/Redo**: safe iteration with reversible edits.
- **Playback controls**: scrubbing, frame stepping, J/K/L shortcuts, loop playback.
- **Clean architecture**: multi-module SwiftPM project with a separated editing core.

## Current MVP Features

- Import local media and add it to a video track
- Timeline: move / trim / snap
- Preview: play / pause / stop / scrub / step frames / loop

## Run (macOS App)

Requires macOS 13+ and Swift 6.

- Build: `swift build --product YunqiMacApp`
- Launch (recommended): `./run-macapp.sh`

## Development

- Tests: `swift test`
- See the design notes: [docs/prepare.md](docs/prepare.md)
