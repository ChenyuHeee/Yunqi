@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AVAssetWriterExecutor: ExportExecutor {
    enum WriterExportError: Error, CustomStringConvertible, LocalizedError {
        case noVideoTrack
        case cannotCreateReader(underlying: Error?)
        case cannotCreateWriter(underlying: Error?)
        case cannotAddReaderOutput
        case cannotAddWriterInput
        case readerFailed(underlying: Error?)
        case writerFailed(underlying: Error?)

        var description: String {
            switch self {
            case .noVideoTrack:
                return "No video track"
            case let .cannotCreateReader(underlying):
                return "Cannot create AVAssetReader: \(underlying?.localizedDescription ?? "nil")"
            case let .cannotCreateWriter(underlying):
                return "Cannot create AVAssetWriter: \(underlying?.localizedDescription ?? "nil")"
            case .cannotAddReaderOutput:
                return "Cannot add reader output"
            case .cannotAddWriterInput:
                return "Cannot add writer input"
            case let .readerFailed(underlying):
                return "Reader failed: \(underlying?.localizedDescription ?? "nil")"
            case let .writerFailed(underlying):
                return "Writer failed: \(underlying?.localizedDescription ?? "nil")"
            }
        }

        var errorDescription: String? { description }
    }

    private struct SendableOpaquePointer: @unchecked Sendable {
        let raw: UnsafeMutableRawPointer
    }

    private struct SendableAsset: @unchecked Sendable {
        let asset: AVAsset
    }

    private struct SendableExportPipeline: @unchecked Sendable {
        let asset: AVAsset
        let videoComposition: AVVideoComposition?
        let audioMix: AVAudioMix?
    }

    func export(job: ExportJob, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        NSLog("[Export][Writer] Start: %@", job.outputURL.path)
        // Build on MainActor (composition building can touch AVFoundation APIs that are safer here).
        let built = await PreviewPlayerController.buildExportPipeline(for: job.project)
        let boxed = SendableExportPipeline(asset: built.asset, videoComposition: built.videoComposition, audioMix: built.audioMix)

        // Overwrite target if exists.
        if FileManager.default.fileExists(atPath: job.outputURL.path) {
            try? FileManager.default.removeItem(at: job.outputURL)
        }

        // Run the heavy read/encode loop off the main actor to avoid UI hitches.
        do {
            try await Task.detached(priority: .userInitiated) {
                try await Self.exportAsset(
                    boxed.asset,
                    videoComposition: boxed.videoComposition,
                    audioMix: boxed.audioMix,
                    to: job.outputURL,
                    fileType: job.fileType,
                    onProgress: onProgress
                )
            }.value
        } catch {
            NSLog("[Export][Writer] Failed: %@", String(describing: error))
            throw error
        }

        onProgress(1.0)
        NSLog("[Export][Writer] Completed")
    }

    private static func inferAudioSettings(from audioTrack: AVAssetTrack) async -> [String: Any] {
        // Default values (safe + predictable). We'll try to follow the source when possible.
        var sampleRate: Double = 44_100
        var channels: Int = 2
        var bitRate: Int = 192_000

        do {
            let descs = try await audioTrack.load(.formatDescriptions)
                if let first = descs.first,
                    CMFormatDescriptionGetMediaType(first) == kCMMediaType_Audio,
                    let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
                let sr = asbdPtr.pointee.mSampleRate
                let ch = Int(asbdPtr.pointee.mChannelsPerFrame)

                if sr.isFinite, sr >= 8_000, sr <= 192_000 { sampleRate = sr }
                if ch == 1 || ch == 2 {
                    channels = ch
                } else if ch > 2 {
                    // Keep minimal scope: AAC multichannel is possible, but it increases compatibility risks.
                    // Clamp to stereo for now.
                    channels = 2
                }

                bitRate = (channels == 1) ? 96_000 : 192_000
            }
        } catch {
            // Keep defaults.
        }

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: bitRate
        ]
    }

    private static func exportAsset(
        _ asset: AVAsset,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        to outputURL: URL,
        fileType: AVFileType,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw WriterExportError.noVideoTrack
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = audioTracks.first

        let durationSeconds = max(0.0, (try await asset.load(.duration)).seconds)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WriterExportError.cannotCreateReader(underlying: error)
        }

        // Decode to uncompressed frames for re-encode.
        let videoReaderOutput: AVAssetReaderOutput = {
            let settings: [String: Any] = [
                // Match MetalVideoCompositor render output (BGRA) to avoid an extra conversion.
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            if let videoComposition {
                let o = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: settings)
                o.videoComposition = videoComposition
                o.alwaysCopiesSampleData = false
                return o
            } else {
                let o = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: settings)
                o.alwaysCopiesSampleData = false
                return o
            }
        }()

        guard reader.canAdd(videoReaderOutput) else {
            throw WriterExportError.cannotAddReaderOutput
        }
        reader.add(videoReaderOutput)

        let audioReaderOutput: AVAssetReaderOutput?
        if let audioTrack {
            // Decode to PCM for re-encode.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ]

            let o: AVAssetReaderOutput
            if let audioMix {
                let mixOut = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: settings)
                mixOut.audioMix = audioMix
                mixOut.alwaysCopiesSampleData = false
                o = mixOut
            } else {
                let trackOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
                trackOut.alwaysCopiesSampleData = false
                o = trackOut
            }

            guard reader.canAdd(o) else {
                throw WriterExportError.cannotAddReaderOutput
            }
            reader.add(o)
            audioReaderOutput = o
        } else {
            audioReaderOutput = nil
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw WriterExportError.cannotCreateWriter(underlying: error)
        }

        // Determine output size.
        // Prefer videoComposition.renderSize (project canvas) so Writer export matches preview/export-session.
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let (width, height): (Int, Int) = {
            if let videoComposition {
                return (
                    Int(max(1, videoComposition.renderSize.width.rounded())),
                    Int(max(1, videoComposition.renderSize.height.rounded()))
                )
            }
            let transformed = naturalSize.applying(preferredTransform)
            return (Int(max(1, abs(transformed.width))), Int(max(1, abs(transformed.height))))
        }()

        // Minimal baseline settings: H.264 in MP4, sized to source.
        // (We can extend codec/bitrate/preset selection later without changing the queue.)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        // If we're reading through videoComposition, frames are already in project canvas space.
        writerInput.transform = (videoComposition == nil) ? preferredTransform : .identity

        guard writer.canAdd(writerInput) else {
            throw WriterExportError.cannotAddWriterInput
        }
        writer.add(writerInput)

        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                // Feed BGRA frames directly; the encoder will handle conversion to its preferred format.
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )

        let audioWriterInput: AVAssetWriterInput?
        if audioTrack != nil {
            let audioSettings = await inferAudioSettings(from: audioTrack!)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw WriterExportError.cannotAddWriterInput
            }
            writer.add(input)
            audioWriterInput = input
        } else {
            audioWriterInput = nil
        }

        guard reader.startReading() else {
            throw WriterExportError.readerFailed(underlying: reader.error)
        }

        guard writer.startWriting() else {
            throw WriterExportError.writerFailed(underlying: writer.error)
        }

        writer.startSession(atSourceTime: .zero)

        // Single pump loop: read both tracks and append in timestamp order.
        var nextVideo: CMSampleBuffer? = nil
        var nextAudio: CMSampleBuffer? = nil
        var videoDone = false
        var audioDone = (audioReaderOutput == nil)
        var lastProgressSent: Double = -1

        func ptsSeconds(_ sample: CMSampleBuffer) -> Double {
            CMSampleBufferGetPresentationTimeStamp(sample).seconds
        }

        while true {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw CancellationError()
            }

            if !videoDone, nextVideo == nil {
                nextVideo = videoReaderOutput.copyNextSampleBuffer()
                if nextVideo == nil { videoDone = true }
            }
            if !audioDone, nextAudio == nil, let audioReaderOutput {
                nextAudio = audioReaderOutput.copyNextSampleBuffer()
                if nextAudio == nil { audioDone = true }
            }

            if nextVideo == nil, nextAudio == nil {
                break
            }

            let takeVideo: Bool
            switch (nextVideo, nextAudio) {
            case let (v?, a?):
                takeVideo = ptsSeconds(v) <= ptsSeconds(a)
            case (_?, nil):
                takeVideo = true
            case (nil, _?):
                takeVideo = false
            default:
                takeVideo = true
            }

            if takeVideo, let sample = nextVideo {
                while !writerInput.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                        throw CancellationError()
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }

                guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    nextVideo = nil
                    continue
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if !pixelBufferAdaptor.append(imageBuffer, withPresentationTime: pts) {
                    throw WriterExportError.writerFailed(underlying: writer.error)
                }
                nextVideo = nil

                if durationSeconds > 0 {
                    let p = max(0, min(1, ptsSeconds(sample) / durationSeconds))
                    if p - lastProgressSent >= 0.01 || lastProgressSent < 0 {
                        lastProgressSent = p
                        onProgress(p)
                    }
                }
            } else if let sample = nextAudio, let audioWriterInput {
                while !audioWriterInput.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                        throw CancellationError()
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                if !audioWriterInput.append(sample) {
                    throw WriterExportError.writerFailed(underlying: writer.error)
                }
                nextAudio = nil
            }
        }

        writerInput.markAsFinished()
        audioWriterInput?.markAsFinished()

        if reader.status == .failed {
            throw WriterExportError.readerFailed(underlying: reader.error)
        }

        let writerPtr = SendableOpaquePointer(raw: Unmanaged.passUnretained(writer).toOpaque())
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                let writer = Unmanaged<AVAssetWriter>.fromOpaque(writerPtr.raw).takeUnretainedValue()
                switch writer.status {
                case .completed:
                    cont.resume()
                case .cancelled:
                    cont.resume(throwing: CancellationError())
                case .failed:
                    cont.resume(throwing: WriterExportError.writerFailed(underlying: writer.error))
                default:
                    cont.resume(throwing: WriterExportError.writerFailed(underlying: writer.error))
                }
            }
        }
    }
}
