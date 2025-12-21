# Yunqi CLI（当前可用命令）

可执行目标：`YunqiApp`

## 运行方式
- `swift run YunqiApp <command> ...`

## 命令
- `init <projectPath> [--name <name>] [--fps <fps>]`
- `import-asset <projectPath> <assetPath> [--id <uuid>]`
- `add-track <projectPath> --kind <video|audio|titles|adjustment>`
- `add-clip <projectPath> --track-index <n> --asset-id <uuid> --start <sec> --duration <sec> [--in <sec>] [--speed <x>]`
- `show <projectPath>`

## 典型流程
1. `swift run YunqiApp init ./demo.project.json --name Demo --fps 30`
2. `swift run YunqiApp import-asset ./demo.project.json /path/to/video.mp4`
3. `swift run YunqiApp add-track ./demo.project.json --kind video`
4. `swift run YunqiApp show ./demo.project.json`
