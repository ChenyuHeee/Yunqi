@preconcurrency import AVFoundation
import Accelerate
import AudioEngine
import Foundation

public struct WaveformCacheKey: Codable, Sendable, Hashable {
    public var assetId: UUID
    /// Best-effort fingerprint for invalidation (nil for unknown/unsupported URLs).
    public var assetFingerprint: String?
    public var startSeconds: Double
    public var durationSeconds: Double
    public var algorithmVersion: Int

    public init(assetId: UUID, assetFingerprint: String? = nil, startSeconds: Double, durationSeconds: Double, algorithmVersion: Int) {
        self.assetId = assetId
        self.assetFingerprint = assetFingerprint
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.algorithmVersion = algorithmVersion
    }
}

public struct WaveformData: Codable, Sendable, Hashable {
    /// Peak envelope in [0, 1].
    public var peak: [Float]
    /// RMS envelope in [0, 1].
    public var rms: [Float]

    /// Optional multi-resolution mip levels (largest -> smallest).
    ///
    /// Backward compatible: older cache files omit this field.
    public var mips: [WaveformMipLevel]?

    public init(peak: [Float], rms: [Float], mips: [WaveformMipLevel]? = nil) {
        self.peak = peak
        self.rms = rms
        self.mips = mips
    }
}

public struct WaveformMipLevel: Codable, Sendable, Hashable {
    public var count: Int
    public var peak: [Float]
    public var rms: [Float]

    public init(count: Int, peak: [Float], rms: [Float]) {
        self.count = max(1, count)
        self.peak = peak
        self.rms = rms
    }
}

public enum WaveformCacheError: Error, Sendable {
    case noAudioTrack
    case readerFailed
    case invalidArguments
}

/// Persistent waveform cache (Phase 1 usable).
///
/// - Computes normalized peak/RMS envelopes over a time range.
/// - Stores a fixed-resolution base waveform on disk, then resamples per UI request.
/// - Not realtime-thread API.
public final class WaveformCache: @unchecked Sendable {
    public static let defaultAlgorithmVersion: Int = 1

    private let baseURL: URL
    private let algorithmVersion: Int

    private let lock = NSLock()
    private var memory: [WaveformCacheKey: WaveformData] = [:]

    /// Fixed base resolution stored on disk.
    private let baseCount: Int

    public init(baseURL: URL, algorithmVersion: Int = WaveformCache.defaultAlgorithmVersion, baseCount: Int = 2048) {
        self.baseURL = baseURL
        self.algorithmVersion = algorithmVersion
        self.baseCount = max(64, baseCount)
    }

    public func loadOrCompute(
        assetId: UUID,
        url: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws -> WaveformData {
        let start = max(0, startSeconds)
        let duration = max(0, durationSeconds)
        guard duration > 0 else { throw WaveformCacheError.invalidArguments }

        let fingerprint = AssetFingerprint.compute(url: url)
        let key = WaveformCacheKey(
            assetId: assetId,
            assetFingerprint: fingerprint,
            startSeconds: start,
            durationSeconds: duration,
            algorithmVersion: algorithmVersion
        )

        if let mem = loadFromMemory(key) { return mem }
        if var disk = try? loadFromDiskWithFallback(key: key) {
            // Upgrade older cache files by computing mips on load.
            if disk.mips == nil {
                disk = Self.withComputedMips(disk)
                try? saveToDisk(key: key, data: disk)
            }
            storeToMemory(key, disk)
            return disk
        }

        var computed = try await Self.computeWaveform(
            url: url,
            startSeconds: start,
            durationSeconds: duration,
            baseCount: baseCount
        )

        if computed.mips == nil {
            computed = Self.withComputedMips(computed)
        }

        storeToMemory(key, computed)
        try? saveToDisk(key: key, data: computed)
        return computed
    }

    public func resampled(
        _ data: WaveformData,
        desiredCount: Int
    ) -> WaveformData {
        let n = max(1, desiredCount)

        // Pick the smallest mip that is still >= desiredCount to reduce work and improve stability.
        if let mips = data.mips, !mips.isEmpty {
            let sorted = mips.sorted { $0.count > $1.count }
            if let best = sorted
                .filter({ $0.count >= n })
                .min(by: { $0.count < $1.count })
            {
                if best.count == n {
                    return WaveformData(peak: best.peak, rms: best.rms, mips: nil)
                }
                return WaveformData(
                    peak: Self.linearResample(values: best.peak, to: n),
                    rms: Self.linearResample(values: best.rms, to: n),
                    mips: nil
                )
            }
        }

        return WaveformData(
            peak: Self.linearResample(values: data.peak, to: n),
            rms: Self.linearResample(values: data.rms, to: n),
            mips: nil
        )
    }

    private static func withComputedMips(_ data: WaveformData) -> WaveformData {
        let baseCount = max(1, min(data.peak.count, data.rms.count))
        guard baseCount > 0 else { return data }

        var levels: [WaveformMipLevel] = []
        levels.reserveCapacity(16)

        var curPeak = Array(data.peak.prefix(baseCount))
        var curRms = Array(data.rms.prefix(baseCount))
        var curCount = baseCount
        levels.append(WaveformMipLevel(count: curCount, peak: curPeak, rms: curRms))

        while curCount > 1 {
            let nextCount = max(1, (curCount + 1) / 2)
            var nextPeak = Array(repeating: Float(0), count: nextCount)
            var nextRms = Array(repeating: Float(0), count: nextCount)

            for i in 0..<nextCount {
                let i0 = i * 2
                let i1 = min(i0 + 1, curCount - 1)
                nextPeak[i] = max(curPeak[i0], curPeak[i1])

                let r0 = curRms[i0]
                let r1 = curRms[i1]
                // Combine RMS from equal-sized buckets: sqrt(mean(square)).
                nextRms[i] = Float(sqrt(0.5 * Double(r0 * r0 + r1 * r1)))
            }

            curPeak = nextPeak
            curRms = nextRms
            curCount = nextCount
            levels.append(WaveformMipLevel(count: curCount, peak: curPeak, rms: curRms))
        }

        // Store largest -> smallest.
        return WaveformData(peak: data.peak, rms: data.rms, mips: levels)
    }

    // MARK: - Disk IO

    private func fileURL(for key: WaveformCacheKey) -> URL {
        let name = Self.stableFileName(for: key)
        return baseURL.appendingPathComponent(name)
    }

    private static func stableFileName(for key: WaveformCacheKey) -> String {
        // Avoid floating-point instability by quantizing to milliseconds.
        let startMs = Int64((key.startSeconds * 1000).rounded(.toNearestOrAwayFromZero))
        let durMs = Int64((key.durationSeconds * 1000).rounded(.toNearestOrAwayFromZero))
        let f: String = {
            guard let fp = key.assetFingerprint, !fp.isEmpty else { return "" }
            return "_f\(AssetFingerprint.fnv1a64Hex(fp))"
        }()
        return "waveform_\(key.assetId.uuidString)\(f)_v\(key.algorithmVersion)_s\(startMs)_d\(durMs).json"
    }

    private func loadFromDiskWithFallback(key: WaveformCacheKey) throws -> WaveformData {
        do {
            return try loadFromDisk(key: key)
        } catch {
            // Backward compatibility: older cache filenames omitted assetFingerprint.
            if key.assetFingerprint != nil {
                let legacy = WaveformCacheKey(
                    assetId: key.assetId,
                    assetFingerprint: nil,
                    startSeconds: key.startSeconds,
                    durationSeconds: key.durationSeconds,
                    algorithmVersion: key.algorithmVersion
                )
                return try loadFromDisk(key: legacy)
            }
            throw error
        }
    }

    private func loadFromDisk(key: WaveformCacheKey) throws -> WaveformData {
        let url = fileURL(for: key)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WaveformData.self, from: data)
    }

    private func saveToDisk(key: WaveformCacheKey, data: WaveformData) throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let url = fileURL(for: key)
        let tmp = url.appendingPathExtension("tmp")
        let encoded = try JSONEncoder().encode(data)
        try encoded.write(to: tmp, options: [.atomic])
        // `.atomic` already swaps, but keep explicit replace to be safe across FS.
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private func loadFromMemory(_ key: WaveformCacheKey) -> WaveformData? {
        lock.lock(); defer { lock.unlock() }
        return memory[key]
    }

    private func storeToMemory(_ key: WaveformCacheKey, _ data: WaveformData) {
        lock.lock(); defer { lock.unlock() }
        memory[key] = data
    }

    // MARK: - Invalidation

    public func invalidate(assetId: UUID) {
        // Memory
        lock.lock()
        memory = memory.filter { $0.key.assetId != assetId }
        lock.unlock()

        // Disk
        let prefix = "waveform_\(assetId.uuidString)"
        guard let items = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            return
        }
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Compute

    private static func computeWaveform(
        url: URL,
        startSeconds: Double,
        durationSeconds: Double,
        baseCount: Int
    ) async throws -> WaveformData {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw WaveformCacheError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WaveformCacheError.readerFailed }
        reader.add(output)

        let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let dur = CMTime(seconds: max(0.001, durationSeconds), preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: start, duration: dur)

        guard reader.startReading() else { throw WaveformCacheError.readerFailed }

        // We compute baseCount buckets: for each bucket, aggregate peak and RMS.
        var peak = Array(repeating: Float(0), count: baseCount)
        var sumSq = Array(repeating: Double(0), count: baseCount)
        var count = Array(repeating: Int(0), count: baseCount)

        // Map incoming samples to buckets by progress in the timeRange.
        // We use sample timestamps if available; otherwise fall back to proportional distribution.
        let totalSeconds = max(0.001, durationSeconds)

        while reader.status == .reading {
            guard let sb = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sb) }

            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }

            var totalLength: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            if status != kCMBlockBufferNoErr { continue }
            guard let dataPointer, totalLength >= 2 else { continue }

            let sampleCount = totalLength / MemoryLayout<Int16>.size
            if sampleCount <= 0 { continue }

            let sampleTime = CMSampleBufferGetPresentationTimeStamp(sb)
            let t0 = max(0.0, CMTimeGetSeconds(sampleTime) - startSeconds)
            let baseIndex = Int((t0 / totalSeconds * Double(baseCount)).rounded(.down))

            let ptr = dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { $0 }

            // Collapse to mono by taking max abs across channels in interleaved stream.
            // Since we don't know channel count here reliably from the output, we treat as a flat stream.
            let idx = min(max(0, baseIndex), baseCount - 1)

            // Fast path (Apple Silicon friendly): use vDSP to convert + compute max magnitude and mean-square.
            var localPeak: Float = 0
            var localSumSq: Double = 0
            var floatScratch = Array(repeating: Float(0), count: sampleCount)
            floatScratch.withUnsafeMutableBufferPointer { out in
                guard let outBase = out.baseAddress else { return }

                vDSP_vflt16(ptr, 1, outBase, 1, vDSP_Length(sampleCount))
                var scale = Float(1.0) / Float(Int16.max)
                vDSP_vsmul(outBase, 1, &scale, outBase, 1, vDSP_Length(sampleCount))

                vDSP_maxmgv(outBase, 1, &localPeak, vDSP_Length(sampleCount))

                var meanSq: Float = 0
                vDSP_measqv(outBase, 1, &meanSq, vDSP_Length(sampleCount))
                localSumSq = Double(meanSq) * Double(sampleCount)
            }

            peak[idx] = max(peak[idx], localPeak)
            sumSq[idx] += localSumSq
            count[idx] += sampleCount
        }

        if reader.status == .failed { throw WaveformCacheError.readerFailed }

        // Normalize peak to [0,1] by max.
        let maxPeak = peak.max() ?? 0
        let peakNorm: [Float] = maxPeak > 0 ? peak.map { $0 / maxPeak } : peak

        // RMS per bucket, then normalize.
        var rms: [Float] = Array(repeating: 0, count: baseCount)
        for i in 0..<baseCount {
            if count[i] > 0 {
                let meanSq = sumSq[i] / Double(count[i])
                rms[i] = Float(sqrt(max(0, meanSq)))
            }
        }
        let maxRms = rms.max() ?? 0
        let rmsNorm: [Float] = maxRms > 0 ? rms.map { $0 / maxRms } : rms

        let base = WaveformData(peak: peakNorm, rms: rmsNorm)
        return withComputedMips(base)
    }

    // MARK: - Resample

    private static func linearResample(values: [Float], to n: Int) -> [Float] {
        let outCount = max(1, n)
        let inCount = max(0, values.count)
        guard inCount > 0 else { return Array(repeating: 0, count: outCount) }
        if inCount == outCount { return values }

        // Deterministic linear resampling.
        var out = Array(repeating: Float(0), count: outCount)
        let ratio = Double(inCount - 1) / Double(max(1, outCount - 1))
        for i in 0..<outCount {
            let x = Double(i) * ratio
            let i0 = Int(floor(x))
            let i1 = min(i0 + 1, inCount - 1)
            let frac = Float(x - Double(i0))
            let a = values[i0]
            let b = values[i1]
            out[i] = a + (b - a) * frac
        }
        return out
    }

}
