import AudioEngine
import Foundation

/// Persistent PCM cache (Phase 1 usable).
///
/// Stores interleaved float32 PCM blocks keyed by `AudioCacheKey` + segment range.
///
/// Notes:
/// - Not realtime-thread API.
/// - Uses best-effort `assetFingerprint` to avoid reusing stale cache when the underlying file changes.
public final class AudioPCMCache: @unchecked Sendable {
    public struct SegmentKey: Codable, Sendable, Hashable {
        public var base: AudioCacheKey
        public var startFrame: Int64
        public var frameCount: Int

        public init(base: AudioCacheKey, startFrame: Int64, frameCount: Int) {
            self.base = base
            self.startFrame = max(0, startFrame)
            self.frameCount = max(0, frameCount)
        }
    }

    private enum FileFormat {
        static let magic: UInt32 = 0x59515043 // 'YQPC'
        static let version: UInt32 = 1
    }

    private let baseURL: URL

    private let lock = NSLock()
    private var memory: [SegmentKey: AudioPCMBlock] = [:]

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Remove cached PCM blocks for a given asset.
    public func invalidate(assetId: UUID) {
        // Memory
        lock.lock()
        memory = memory.filter { $0.key.base.assetId != assetId }
        lock.unlock()

        // Disk
        let prefix = "pcm_\(assetId.uuidString)"
        guard let items = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            return
        }
        for url in items {
            if url.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Load from cache if present, otherwise compute and persist.
    public func loadOrCompute(
        key: SegmentKey,
        compute: () throws -> AudioPCMBlock
    ) throws -> AudioPCMBlock {
        if let mem = loadFromMemory(key) { return mem }
        if let disk = try? loadFromDisk(key: key) {
            storeToMemory(key, disk)
            return disk
        }

        let computed = try compute()
        storeToMemory(key, computed)
        try? saveToDisk(key: key, block: computed)
        return computed
    }

    // MARK: - Memory

    private func loadFromMemory(_ key: SegmentKey) -> AudioPCMBlock? {
        lock.lock(); defer { lock.unlock() }
        return memory[key]
    }

    private func storeToMemory(_ key: SegmentKey, _ block: AudioPCMBlock) {
        lock.lock(); defer { lock.unlock() }
        memory[key] = block
    }

    // MARK: - Disk

    private func fileURL(for key: SegmentKey) -> URL {
        baseURL.appendingPathComponent(Self.stableFileName(for: key))
    }

    private static func stableFileName(for key: SegmentKey) -> String {
        let a = key.base.assetId.uuidString
        let c = key.base.clipId.uuidString

        let fpTag: String = {
            guard let fp = key.base.assetFingerprint, !fp.isEmpty else { return "" }
            return "_f\(AssetFingerprint.fnv1a64Hex(fp))"
        }()

        let plan = String(format: "%016llx", key.base.planStableHash64)
        let v = key.base.algorithmVersion

        let sr = Int64((key.base.format.sampleRate).rounded(.toNearestOrAwayFromZero))
        let ch = key.base.format.channelCount

        let s = key.startFrame
        let n = key.frameCount

        return "pcm_\(a)_c\(c)\(fpTag)_p\(plan)_v\(v)_sr\(sr)_ch\(ch)_s\(s)_n\(n).bin"
    }

    private func loadFromDisk(key: SegmentKey) throws -> AudioPCMBlock {
        let url = fileURL(for: key)
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    private func saveToDisk(key: SegmentKey, block: AudioPCMBlock) throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let url = fileURL(for: key)
        let tmp = url.appendingPathExtension("tmp")
        let data = try encode(block)
        try data.write(to: tmp, options: [.atomic])
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Codec

    private func encode(_ block: AudioPCMBlock) throws -> Data {
        var data = Data()
        data.reserveCapacity(32 + block.interleaved.count * MemoryLayout<Float>.size)

        func appendU32(_ x: UInt32) {
            var le = x.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        func appendI64(_ x: Int64) {
            var le = x.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        func appendF64(_ x: Double) {
            var bits = x.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        appendU32(FileFormat.magic)
        appendU32(FileFormat.version)
        appendU32(UInt32(max(1, block.channelCount)))
        appendU32(UInt32(max(0, block.frameCount)))
        appendF64(0) // reserved for future (e.g., source sampleRate)
        appendI64(Int64(block.interleaved.count))

        // Float32 little-endian.
        for f in block.interleaved {
            var bits = f.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        return data
    }

    private func decode(_ data: Data) throws -> AudioPCMBlock {
        enum DecodeError: Error {
            case truncated
            case badMagic
            case badVersion
            case badPayload
        }

        func readU32(_ offset: inout Int) throws -> UInt32 {
            let n = 4
            guard offset + n <= data.count else { throw DecodeError.truncated }
            let v: UInt32 = data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: UInt32.self)
            }
            offset += n
            return UInt32(littleEndian: v)
        }

        func readI64(_ offset: inout Int) throws -> Int64 {
            let n = 8
            guard offset + n <= data.count else { throw DecodeError.truncated }
            let v: Int64 = data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: Int64.self)
            }
            offset += n
            return Int64(littleEndian: v)
        }

        func readF64(_ offset: inout Int) throws -> Double {
            let n = 8
            guard offset + n <= data.count else { throw DecodeError.truncated }
            let v: UInt64 = data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: UInt64.self)
            }
            offset += n
            return Double(bitPattern: UInt64(littleEndian: v))
        }

        var off = 0
        let magic = try readU32(&off)
        guard magic == FileFormat.magic else { throw DecodeError.badMagic }
        let version = try readU32(&off)
        guard version == FileFormat.version else { throw DecodeError.badVersion }

        let channelCount = Int(try readU32(&off))
        let frameCount = Int(try readU32(&off))
        _ = try readF64(&off) // reserved
        let sampleCount = Int(try readI64(&off))

        let expected = max(0, channelCount) * max(0, frameCount)
        guard sampleCount == expected else { throw DecodeError.badPayload }

        let bytesNeeded = sampleCount * MemoryLayout<UInt32>.size
        guard off + bytesNeeded <= data.count else { throw DecodeError.truncated }

        var out: [Float] = []
        out.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let byteOffset = off + i * 4
            let bits: UInt32 = data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: byteOffset, as: UInt32.self)
            }
            out.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }

        return AudioPCMBlock(channelCount: max(1, channelCount), frameCount: max(0, frameCount), interleaved: out)
    }
}
