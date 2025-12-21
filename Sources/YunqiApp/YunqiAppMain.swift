import Foundation
import EditorCore
import Storage

@main
struct YunqiAppCLI {
    static func main() throws {
        let cli = CLI(store: JSONProjectStore())
        try cli.run(CommandLine.arguments)
    }
}

private struct CLI {
    private let store: ProjectStore

    init(store: ProjectStore) {
        self.store = store
    }

    func run(_ argv: [String]) throws {
        let args = Array(argv.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        let tail = Array(args.dropFirst())
        switch command {
        case "init":
            try cmdInit(tail)
        case "import-asset":
            try cmdImportAsset(tail)
        case "add-track":
            try cmdAddTrack(tail)
        case "add-clip":
            try cmdAddClip(tail)
        case "show":
            try cmdShow(tail)
        case "help", "-h", "--help":
            printUsage()
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private func cmdInit(_ args: [String]) throws {
        var parser = ArgParser(args)
        let projectPath = try parser.requirePositional("projectPath")
        let name = parser.option("--name") ?? "Yunqi Project"
        let fps = Double(parser.option("--fps") ?? "30") ?? 30
        parser.ensureFullyConsumed()

        let url = URL(fileURLWithPath: projectPath)
        let project = Project(meta: ProjectMeta(name: name, fps: fps))
        try store.save(project, to: url)
        print("Created project: \(url.path)")
    }

    private func cmdImportAsset(_ args: [String]) throws {
        var parser = ArgParser(args)
        let projectPath = try parser.requirePositional("projectPath")
        let assetPath = try parser.requirePositional("assetPath")
        let id = UUID(uuidString: parser.option("--id") ?? "")
        parser.ensureFullyConsumed()

        let url = URL(fileURLWithPath: projectPath)
        let project = try store.load(from: url)
        let editor = ProjectEditor(project: project)
        let assetId = editor.importAsset(path: assetPath, id: id ?? UUID())
        try store.save(editor.project, to: url)
        print("Imported asset: \(assetId.uuidString)")
    }

    private func cmdAddTrack(_ args: [String]) throws {
        var parser = ArgParser(args)
        let projectPath = try parser.requirePositional("projectPath")
        let kindRaw = parser.option("--kind") ?? "video"
        parser.ensureFullyConsumed()

        guard let kind = TrackKind(rawValue: kindRaw) else {
            throw CLIError.invalidOption("--kind", kindRaw)
        }

        let url = URL(fileURLWithPath: projectPath)
        let project = try store.load(from: url)
        let editor = ProjectEditor(project: project)
        editor.addTrack(kind: kind)
        try store.save(editor.project, to: url)
        print("Added track: \(kind.rawValue)")
    }

    private func cmdAddClip(_ args: [String]) throws {
        var parser = ArgParser(args)
        let projectPath = try parser.requirePositional("projectPath")
        let trackIndex = Int(parser.option("--track-index") ?? "")
        let assetId = UUID(uuidString: parser.option("--asset-id") ?? "")
        let start = Double(parser.option("--start") ?? "")
        let sourceIn = Double(parser.option("--in") ?? "0") ?? 0
        let duration = Double(parser.option("--duration") ?? "")
        let speed = Double(parser.option("--speed") ?? "1") ?? 1
        parser.ensureFullyConsumed()

        guard let trackIndex else { throw CLIError.missingOption("--track-index") }
        guard let assetId else { throw CLIError.missingOption("--asset-id") }
        guard let start else { throw CLIError.missingOption("--start") }
        guard let duration else { throw CLIError.missingOption("--duration") }

        let url = URL(fileURLWithPath: projectPath)
        let project = try store.load(from: url)
        let editor = ProjectEditor(project: project)
        do {
            try editor.addClip(
                trackIndex: trackIndex,
                assetId: assetId,
                timelineStartSeconds: start,
                sourceInSeconds: sourceIn,
                durationSeconds: duration,
                speed: speed
            )
        } catch let error as ProjectEditError {
            throw CLIError.projectEdit(error.description)
        }
        try store.save(editor.project, to: url)
        print("Added clip on track \(trackIndex)")
    }

    private func cmdShow(_ args: [String]) throws {
        var parser = ArgParser(args)
        let projectPath = try parser.requirePositional("projectPath")
        parser.ensureFullyConsumed()

        let url = URL(fileURLWithPath: projectPath)
        let project = try store.load(from: url)

        print("Project: \(project.meta.name)")
        print("FPS: \(project.meta.fps)")
        print("Assets: \(project.mediaAssets.count)")
        for (index, asset) in project.mediaAssets.enumerated() {
            print("  [\(index)] \(asset.id.uuidString)  \(asset.originalPath)")
        }
        print("Tracks: \(project.timeline.tracks.count)")
        for (idx, track) in project.timeline.tracks.enumerated() {
            print("  [\(idx)] \(track.kind.rawValue)  clips=\(track.clips.count)")
        }
    }

    private func printUsage() {
        let usage = #"""
Yunqi CLI

USAGE:
  yunqi <command> [arguments] [options]

COMMANDS:
  init <projectPath> [--name <name>] [--fps <fps>]
  import-asset <projectPath> <assetPath> [--id <uuid>]
  add-track <projectPath> --kind <video|audio|titles|adjustment>
  add-clip <projectPath> --track-index <n> --asset-id <uuid> --start <sec> --duration <sec> [--in <sec>] [--speed <x>]
  show <projectPath>

EXAMPLE:
  swift run YunqiApp init ./demo.project.json --name Demo --fps 30
  swift run YunqiApp import-asset ./demo.project.json /path/to/video.mp4
  swift run YunqiApp add-track ./demo.project.json --kind video
  swift run YunqiApp show ./demo.project.json
"""#
        print(usage)
    }
}

private struct ArgParser {
    private var positionals: [String] = []
    private var options: [String: String?] = [:]
    private var extra: [String] = []

    init(_ args: [String]) {
        var index = 0
        while index < args.count {
            let token = args[index]
            if token.hasPrefix("--") {
                let key = token
                let next = (index + 1) < args.count ? args[index + 1] : nil
                if let next, !next.hasPrefix("--") {
                    options[key] = next
                    index += 2
                } else {
                    options[key] = nil
                    index += 1
                }
            } else {
                positionals.append(token)
                index += 1
            }
        }
    }

    mutating func requirePositional(_ name: String) throws -> String {
        guard !positionals.isEmpty else {
            throw CLIError.missingPositional(name)
        }
        return positionals.removeFirst()
    }

    func option(_ key: String) -> String? {
        guard let value = options[key] else { return nil }
        return value ?? "true"
    }

    func ensureFullyConsumed() {
        if !extra.isEmpty {
            // reserved for future parsing rules
        }
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case missingPositional(String)
    case missingOption(String)
    case invalidOption(String, String)
    case projectEdit(String)

    var description: String {
        switch self {
        case let .unknownCommand(cmd):
            return "Unknown command: \(cmd)"
        case let .missingPositional(name):
            return "Missing positional argument: \(name)"
        case let .missingOption(key):
            return "Missing option: \(key)"
        case let .invalidOption(key, value):
            return "Invalid option \(key): \(value)"
        case let .projectEdit(message):
            return "Project edit error: \(message)"
        }
    }
}
