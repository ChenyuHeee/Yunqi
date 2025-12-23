@preconcurrency import AVFoundation
import AudioEngine
import Foundation

public final class AVFoundationAudioDecodeSource: AudioDecodeSource, @unchecked Sendable {
    public let sourceFormat: AudioSourceFormat
    public let durationFrames: Int64
    public let preferredChunkFrames: Int

    private let asset: AVAsset
    private let track: AVAssetTrack

    // Prefer AVAudioFile for local PCM reads (reliable duration + sample-accurate seeks).
    private let pcmFile: AVAudioFile?

    // Simple read-through cache for sequential reads.
    private let lock = NSLock()
    private var cacheStartFrame: Int64 = 0
    private var cacheFrameCount: Int = 0
    private var cacheInterleaved: [Float] = []

    public init(url: URL, preferredChunkFrames: Int = 4096) async throws {
        self.preferredChunkFrames = max(256, preferredChunkFrames)

        // Attempt AVAudioFile first (works well for PCM containers like WAV/AIFF).
        let pcm = try? AVAudioFile(forReading: url)
        self.pcmFile = pcm

        let asset = AVAsset(url: url)
        self.asset = asset

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioDecodeSourceError.noAudioTrack
        }
        self.track = track

        if let pcm {
            let sr = pcm.processingFormat.sampleRate
            let ch = Int(pcm.processingFormat.channelCount)
            self.sourceFormat = AudioSourceFormat(sampleRate: sr, channelCount: max(1, ch))
            self.durationFrames = max(0, pcm.length)
        } else {
            let format = try await Self.loadSourceFormat(track: track)
            self.sourceFormat = format

            let durationSeconds = try await Self.loadDurationSeconds(asset: asset)
            let frames = (durationSeconds * format.sampleRate).rounded(.toNearestOrAwayFromZero)
            self.durationFrames = max(0, Int64(frames))
        }
    }

    public func readPCM(startFrame: Int64, frameCount: Int) throws -> AudioPCMBlock {
        let start = max(0, startFrame)
        let requested = max(0, frameCount)
        let channels = sourceFormat.channelCount

        guard requested > 0 else {
            return AudioPCMBlock(channelCount: channels, frameCount: 0, interleaved: [])
        }

        if start >= durationFrames {
            return .silence(channelCount: channels, frameCount: requested)
        }

        // Clamp to available frames; we will pad to `requested`.
        let available = Int(max(0, min(Int64(requested), durationFrames - start)))

        // Fast path: AVAudioFile for PCM.
        if let pcmFile {
            let block = try readPCMViaAudioFile(pcmFile, startFrame: start, frameCount: available)
            return padIfNeeded(block, toFrameCount: requested)
        }

        if let cached = readFromCache(startFrame: start, frameCount: available) {
            return padIfNeeded(cached, toFrameCount: requested)
        }

        // Decode a window larger than requested to make sequential reads efficient.
        let windowFrames = max(available, preferredChunkFrames * 4)
        let alignedStart = (start / Int64(preferredChunkFrames)) * Int64(preferredChunkFrames)
        let decodeCount = Int(min(Int64(windowFrames), max(0, durationFrames - alignedStart)))

        let decoded = try decodeRange(startFrame: alignedStart, frameCount: decodeCount)
        writeCache(startFrame: alignedStart, block: decoded)

        // Slice out the requested portion.
        let offset = Int(max(0, start - alignedStart))
        let sliced = slice(decoded, offsetFrames: offset, frameCount: available)
        return padIfNeeded(sliced, toFrameCount: requested)
    }

    private func readPCMViaAudioFile(_ file: AVAudioFile, startFrame: Int64, frameCount: Int) throws -> AudioPCMBlock {
        let channels = sourceFormat.channelCount
        guard frameCount > 0 else {
            return AudioPCMBlock(channelCount: channels, frameCount: 0, interleaved: [])
        }

        // AVAudioFile is not documented as thread-safe; serialize access.
        lock.lock(); defer { lock.unlock() }

        file.framePosition = max(0, startFrame)
        let fmt = file.processingFormat
        guard fmt.commonFormat == .pcmFormatFloat32 else {
            throw AudioDecodeSourceError.formatUnavailable
        }

        let capacity = AVAudioFrameCount(frameCount)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else {
            throw AudioDecodeSourceError.sampleBufferReadFailed
        }

        try file.read(into: buf, frameCount: capacity)
        let readFrames = Int(buf.frameLength)
        if readFrames <= 0 {
            return AudioPCMBlock(channelCount: channels, frameCount: 0, interleaved: [])
        }

        // AVAudioPCMBuffer floatChannelData is non-interleaved; interleave deterministically.
        guard let chData = buf.floatChannelData else {
            throw AudioDecodeSourceError.sampleBufferReadFailed
        }

        var out = Array(repeating: Float(0), count: readFrames * channels)
        for ch in 0..<channels {
            let src = chData[ch]
            for i in 0..<readFrames {
                out[i * channels + ch] = src[i]
            }
        }

        return AudioPCMBlock(channelCount: channels, frameCount: readFrames, interleaved: out)
    }

    private func readFromCache(startFrame: Int64, frameCount: Int) -> AudioPCMBlock? {
        lock.lock(); defer { lock.unlock() }
        guard cacheFrameCount > 0 else { return nil }
        guard startFrame >= cacheStartFrame else { return nil }
        let end = startFrame + Int64(frameCount)
        let cacheEnd = cacheStartFrame + Int64(cacheFrameCount)
        guard end <= cacheEnd else { return nil }

        let offsetFrames = Int(startFrame - cacheStartFrame)
        let channels = sourceFormat.channelCount
        let startIdx = offsetFrames * channels
        let endIdx = startIdx + frameCount * channels
        guard startIdx >= 0, endIdx <= cacheInterleaved.count else { return nil }

        return AudioPCMBlock(
            channelCount: channels,
            frameCount: frameCount,
            interleaved: Array(cacheInterleaved[startIdx..<endIdx])
        )
    }

    private func writeCache(startFrame: Int64, block: AudioPCMBlock) {
        lock.lock(); defer { lock.unlock() }
        cacheStartFrame = startFrame
        cacheFrameCount = block.frameCount
        cacheInterleaved = block.interleaved
    }

    private func padIfNeeded(_ block: AudioPCMBlock, toFrameCount targetFrames: Int) -> AudioPCMBlock {
        let channels = block.channelCount
        let n = max(0, targetFrames)
        if block.frameCount >= n { return block }
        var out = block.interleaved
        out.append(contentsOf: Array(repeating: 0, count: (n - block.frameCount) * channels))
        return AudioPCMBlock(channelCount: channels, frameCount: n, interleaved: out)
    }

    private func slice(_ block: AudioPCMBlock, offsetFrames: Int, frameCount: Int) -> AudioPCMBlock {
        let channels = block.channelCount
        let off = max(0, offsetFrames)
        let count = max(0, frameCount)
        if count == 0 {
            return AudioPCMBlock(channelCount: channels, frameCount: 0, interleaved: [])
        }

        let start = min(block.frameCount, off)
        let end = min(block.frameCount, start + count)
        let startIdx = start * channels
        let endIdx = end * channels
        if startIdx >= endIdx { return AudioPCMBlock(channelCount: channels, frameCount: 0, interleaved: []) }

        return AudioPCMBlock(channelCount: channels, frameCount: end - start, interleaved: Array(block.interleaved[startIdx..<endIdx]))
    }

    private func decodeRange(startFrame: Int64, frameCount: Int) throws -> AudioPCMBlock {
        let channels = sourceFormat.channelCount
        let sr = sourceFormat.sampleRate

        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioDecodeSourceError.assetReaderSetupFailed }
        reader.add(output)

        // Use a sample-accurate timescale so very short reads (a few frames) work correctly.
        let ts = Int32(max(1, min(192_000, Int(sr.rounded(.toNearestOrAwayFromZero)))))
        let start = CMTime(value: CMTimeValue(max(0, startFrame)), timescale: ts)
        let dur = CMTime(value: CMTimeValue(max(1, frameCount)), timescale: ts)
        reader.timeRange = CMTimeRange(start: start, duration: dur)

        guard reader.startReading() else {
            throw AudioDecodeSourceError.assetReaderStartFailed
        }

        var interleaved: [Float] = []
        interleaved.reserveCapacity(frameCount * channels)

        while reader.status == .reading, interleaved.count < frameCount * channels {
            guard let sb = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sb) }

            let sampleCount = CMSampleBufferGetNumSamples(sb)
            if sampleCount <= 0 { continue }

            var blockBuffer: CMBlockBuffer?
            var audioBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: 0,
                    mData: nil
                )
            )

            var dataSize: Int = 0
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sb,
                bufferListSizeNeededOut: &dataSize,
                bufferListOut: &audioBufferList,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            if status != noErr {
                throw AudioDecodeSourceError.sampleBufferReadFailed
            }

            // Expect interleaved float32 in a single buffer.
            let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
            guard let first = buffers.first else { continue }
            guard first.mNumberChannels == UInt32(channels) else {
                throw AudioDecodeSourceError.channelMismatch
            }
            guard let data = first.mData else { continue }

            let floatCount = sampleCount * channels
            let byteCount = floatCount * MemoryLayout<Float>.size
            if first.mDataByteSize < byteCount {
                throw AudioDecodeSourceError.sampleBufferReadFailed
            }

            let ptr = data.bindMemory(to: Float.self, capacity: floatCount)
            interleaved.append(contentsOf: UnsafeBufferPointer(start: ptr, count: floatCount))
        }

        if reader.status == .failed {
            throw AudioDecodeSourceError.assetReaderReadFailed
        }

        // Ensure exact length.
        let totalFrames = min(frameCount, interleaved.count / channels)
        if totalFrames <= 0 {
            return AudioPCMBlock(channelCount: channels, frameCount: 0, interleaved: [])
        }
        if interleaved.count > totalFrames * channels {
            interleaved.removeLast(interleaved.count - totalFrames * channels)
        }

        return AudioPCMBlock(channelCount: channels, frameCount: totalFrames, interleaved: interleaved)
    }

    private static func loadSourceFormat(track: AVAssetTrack) async throws -> AudioSourceFormat {
        let descs = try await track.load(.formatDescriptions)
        guard let first = descs.first,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(first) else {
            throw AudioDecodeSourceError.formatUnavailable
        }
        let sr = asbdPtr.pointee.mSampleRate
        let ch = Int(asbdPtr.pointee.mChannelsPerFrame)
        guard sr.isFinite, sr > 0 else { throw AudioDecodeSourceError.formatUnavailable }
        return AudioSourceFormat(sampleRate: sr, channelCount: max(1, ch))
    }

    private static func loadDurationSeconds(asset: AVAsset) async throws -> Double {
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite else { return 0 }
        return max(0, seconds)
    }
}

public enum AudioDecodeSourceError: Error, Sendable {
    case noAudioTrack
    case formatUnavailable
    case assetReaderSetupFailed
    case assetReaderStartFailed
    case assetReaderReadFailed
    case sampleBufferReadFailed
    case channelMismatch
}
