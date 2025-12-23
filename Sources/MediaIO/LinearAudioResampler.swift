import AudioEngine
import Foundation

public struct LinearAudioResampler: AudioResampler {
    public init() {}

    public func process(
        input: AudioPCMBlock,
        fromRate: Double,
        toRate: Double,
        quality: AudioResampleQuality
    ) throws -> AudioPCMBlock {
        guard fromRate.isFinite, toRate.isFinite, fromRate > 0, toRate > 0 else {
            throw AudioResamplerError.invalidSampleRate
        }

        // Fast path: same rate.
        if fromRate == toRate || abs(fromRate - toRate) < 1e-9 {
            return input
        }

        let inFrames = max(0, input.frameCount)
        let channels = max(1, input.channelCount)
        if inFrames == 0 {
            return AudioPCMBlock(channelCount: channels, frameCount: 0, interleaved: [])
        }

        let ratio = toRate / fromRate
        // Deterministic rounding.
        let outFrames = max(0, Int((Double(inFrames) * ratio).rounded(.toNearestOrAwayFromZero)))
        if outFrames == 0 {
            return AudioPCMBlock(channelCount: channels, frameCount: 0, interleaved: [])
        }

        var out = Array(repeating: Float(0), count: outFrames * channels)
        out.withUnsafeMutableBufferPointer { outPtr in
            input.interleaved.withUnsafeBufferPointer { inPtr in
                switch quality {
                case .realtime:
                    // Linear interpolation (cheap but usable).
                    for outFrame in 0..<outFrames {
                        let inPos = Double(outFrame) / ratio
                        var i0 = Int(floor(inPos))
                        if i0 < 0 { i0 = 0 }
                        if i0 >= inFrames { i0 = inFrames - 1 }
                        let i1 = min(i0 + 1, inFrames - 1)
                        let frac = Float(inPos - Double(i0))

                        let in0Base = i0 * channels
                        let in1Base = i1 * channels
                        let outBase = outFrame * channels
                        for ch in 0..<channels {
                            let a = inPtr[in0Base + ch]
                            let b = inPtr[in1Base + ch]
                            outPtr[outBase + ch] = a + (b - a) * frac
                        }
                    }

                case .high:
                    // Windowed-sinc resampling for higher quality.
                    // Fixed taps for deterministic behavior.
                    let taps = 32
                    let half = taps / 2
                    let pi = Double.pi

                    // Hann window.
                    func window(_ n: Int) -> Double {
                        // n in [0, taps-1]
                        0.5 - 0.5 * cos(2.0 * pi * Double(n) / Double(taps - 1))
                    }

                    func sinc(_ x: Double) -> Double {
                        if x == 0 { return 1 }
                        let pix = pi * x
                        return sin(pix) / pix
                    }

                    for outFrame in 0..<outFrames {
                        let inPos = Double(outFrame) / ratio
                        let center = Int(floor(inPos))
                        let frac = inPos - Double(center)

                        let outBase = outFrame * channels
                        for ch in 0..<channels {
                            var acc: Double = 0
                            var wsum: Double = 0

                            for t in 0..<taps {
                                let k = t - half + 1
                                var idx = center + k
                                if idx < 0 { idx = 0 }
                                if idx >= inFrames { idx = inFrames - 1 }

                                let x = Double(k) - frac
                                let w = window(t) * sinc(x)
                                wsum += w
                                acc += Double(inPtr[idx * channels + ch]) * w
                            }

                            if wsum != 0 {
                                acc /= wsum
                            }
                            outPtr[outBase + ch] = Float(acc)
                        }
                    }
                }
            }
        }

        return AudioPCMBlock(channelCount: channels, frameCount: outFrames, interleaved: out)
    }
}

public enum AudioResamplerError: Error, Sendable {
    case invalidSampleRate
}
