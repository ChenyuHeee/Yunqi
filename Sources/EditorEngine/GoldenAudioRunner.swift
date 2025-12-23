import AudioEngine
import Foundation

/// Golden test runner (Phase 1 scaffold).
///
/// Runs a `GoldenAudioCase` through an `OfflineAudioRenderer` and produces a deterministic
/// `AudioPCMGoldenSnapshot` for comparison.
///
/// This intentionally performs no file IO.
public enum GoldenAudioRunner {
    public static func run(case c: GoldenAudioCase, renderer: any OfflineAudioRenderer) throws -> AudioPCMGoldenSnapshot {
        let clock = AudioClock(sampleRate: c.outputFormat.sampleRate)
        let startSampleTime = clock.sampleTime(timelineSeconds: c.startSeconds)

        let framesExact = c.durationSeconds * c.outputFormat.sampleRate
        let frameCount = max(0, Int(framesExact.rounded(.toNearestOrAwayFromZero)))

        let block = try renderer.render(
            startSampleTime: startSampleTime,
            frameCount: frameCount,
            format: c.outputFormat
        )

        return AudioGolden.snapshot(
            format: c.outputFormat,
            frameCount: block.frameCount,
            interleaved: block.interleaved
        )
    }
}
