import AudioEngine
import EditorCore
import Foundation

/// Golden test case definition (Phase 1 scaffold).
///
/// This provides a stable, reproducible way to describe:
/// - input project
/// - time range to render
/// - expected PCM summary snapshot
///
/// It intentionally does not perform any IO.
public struct GoldenAudioCase: Sendable, Codable {
    public var schemaVersion: Int

    /// Human-friendly name. Not used as the stable key.
    public var name: String

    /// Full project input.
    public var project: Project

    /// Timeline time range (seconds). End is exclusive.
    public var startSeconds: Double
    public var durationSeconds: Double

    public var quality: AudioRenderQuality
    public var outputFormat: AudioSourceFormat

    /// Expected output snapshot produced by OfflineRenderer later.
    public var expected: AudioPCMGoldenSnapshot

    public init(
        schemaVersion: Int = 1,
        name: String,
        project: Project,
        startSeconds: Double,
        durationSeconds: Double,
        quality: AudioRenderQuality,
        outputFormat: AudioSourceFormat,
        expected: AudioPCMGoldenSnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.project = project
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.quality = quality
        self.outputFormat = outputFormat
        self.expected = expected
    }

    /// Stable identifier for storing this golden case on disk.
    ///
    /// - Deterministic across machines/processes
    /// - Independent of dictionary insertion order inside `Project` JSON encoding
    public var stableKey64: UInt64 {
        var h = FNV1a64()
        h.combine(string: "GoldenAudioCase")
        h.combine(int: schemaVersion)

        // Project identity: keep it minimal and stable.
        // If needed later, add a dedicated project fingerprint.
        h.combine(string: project.meta.name)
        h.combine(double: project.meta.fps)
        h.combine(int: project.meta.renderSize.width)
        h.combine(int: project.meta.renderSize.height)

        h.combine(double: startSeconds)
        h.combine(double: durationSeconds)
        h.combine(string: quality.rawValue)
        h.combine(double: outputFormat.sampleRate)
        h.combine(int: outputFormat.channelCount)

        return h.value
    }

    public var stableFileName: String {
        String(format: "%016llx.json", stableKey64)
    }

    public func encodeDeterministicJSON(prettyPrinted: Bool = false) throws -> Data {
        let enc = JSONEncoder()
        var fmt: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted {
            fmt.insert(.prettyPrinted)
        }
        enc.outputFormatting = fmt
        return try enc.encode(self)
    }
}

private struct FNV1a64 {
    private(set) var value: UInt64 = 0xcbf29ce484222325

    mutating func combine(bytes: UnsafeRawBufferPointer) {
        for b in bytes {
            value ^= UInt64(b)
            value &*= 0x00000100000001B3
        }
    }

    mutating func combine(string: String) {
        string.utf8.withContiguousStorageIfAvailable { buf in
            combine(bytes: UnsafeRawBufferPointer(buf))
        } ?? {
            let arr = Array(string.utf8)
            arr.withUnsafeBytes { combine(bytes: $0) }
        }()
    }

    mutating func combine(int: Int) {
        var x = Int64(int)
        withUnsafeBytes(of: &x) { combine(bytes: $0) }
    }

    mutating func combine(uint64: UInt64) {
        var x = uint64
        withUnsafeBytes(of: &x) { combine(bytes: $0) }
    }

    mutating func combine(double: Double) {
        var x = double.bitPattern
        withUnsafeBytes(of: &x) { combine(bytes: $0) }
    }
}
