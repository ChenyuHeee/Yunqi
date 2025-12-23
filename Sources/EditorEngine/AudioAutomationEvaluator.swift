import EditorCore
import Foundation

enum AudioAutomationEvaluator {
    /// Evaluate a `Double` automation curve at a given clip-local time.
    ///
    /// Semantics (Phase 1):
    /// - If curve has no keyframes: return `defaultValue`.
    /// - If `t` is before first keyframe: return first value.
    /// - If `t` is after last keyframe: return last value.
    /// - Between keys: use the *left* keyframe's interpolation mode.
    static func value(
        curve: AudioAutomationCurve<Double>?,
        atTimeSeconds t: Double,
        defaultValue: Double
    ) -> Double {
        guard let curve else { return defaultValue }
        let raw = curve.keyframes
        guard raw.isEmpty == false else { return defaultValue }

        let time = t.isFinite ? t : 0

        // Deterministic ordering: by time, then value, then interpolation.
        let keys = raw.sorted {
            if abs($0.timeSeconds - $1.timeSeconds) > 1e-12 { return $0.timeSeconds < $1.timeSeconds }
            if abs($0.value - $1.value) > 1e-12 { return $0.value < $1.value }
            return $0.interpolation.rawValue < $1.interpolation.rawValue
        }

        if time <= keys[0].timeSeconds + 1e-12 { return keys[0].value }
        if time >= keys[keys.count - 1].timeSeconds - 1e-12 { return keys[keys.count - 1].value }

        // Find segment [i, i+1] such that keys[i].time <= time < keys[i+1].time.
        for i in 0..<(keys.count - 1) {
            let a = keys[i]
            let b = keys[i + 1]
            if time < a.timeSeconds - 1e-12 { continue }
            if time >= b.timeSeconds - 1e-12 { continue }

            switch a.interpolation {
            case .hold:
                return a.value
            case .linear:
                let dt = b.timeSeconds - a.timeSeconds
                if abs(dt) < 1e-12 { return b.value }
                let u = (time - a.timeSeconds) / dt
                return a.value + (b.value - a.value) * u
            }
        }

        // Fallback: should be unreachable due to boundary checks.
        return keys[keys.count - 1].value
    }
}
