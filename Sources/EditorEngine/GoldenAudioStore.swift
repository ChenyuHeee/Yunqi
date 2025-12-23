import AudioEngine
import Foundation

/// Minimal JSON file store for audio golden snapshots.
///
/// - Deterministic encoding via `sortedKeys`
/// - No realtime concerns (test/diagnostics only)
public enum GoldenAudioStore {
    public static let updateGoldensEnv: String = "YUNQI_UPDATE_GOLDENS"

    public static func shouldUpdateGoldens(from env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env[updateGoldensEnv] == "1" || env[updateGoldensEnv] == "true"
    }

    public static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let enc = JSONEncoder()
        var fmt: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted {
            fmt.insert(.prettyPrinted)
        }
        enc.outputFormatting = fmt
        return enc
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func goldenFileURL(baseURL: URL, fileName: String) -> URL {
        baseURL.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func loadSnapshot(from url: URL) throws -> AudioPCMGoldenSnapshot {
        let data = try Data(contentsOf: url)
        return try makeDecoder().decode(AudioPCMGoldenSnapshot.self, from: data)
    }

    public static func saveSnapshot(_ snapshot: AudioPCMGoldenSnapshot, to url: URL, prettyPrinted: Bool = true) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try makeEncoder(prettyPrinted: prettyPrinted).encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }
}
