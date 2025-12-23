import Foundation
import Atomics

public enum AudioRenderQuality: String, Codable, Sendable {
    case realtime
    case high
}

// MARK: - Diagnostics (Phase 1)

public struct AudioDiagnostics: Sendable, Hashable {
    public var bufferPoolUnderflows: UInt64

    /// Aggregated callback duration distribution (Phase 1: collector is lock-based).
    public var callbackTiming: AudioCallbackTimingSnapshot

    /// Aggregated cache hit/miss counters (Phase 1: collector is lock-based).
    public var cacheMetrics: AudioCacheMetricsSnapshot

    public init(
        bufferPoolUnderflows: UInt64 = 0,
        callbackTiming: AudioCallbackTimingSnapshot = AudioCallbackTimingSnapshot(),
        cacheMetrics: AudioCacheMetricsSnapshot = AudioCacheMetricsSnapshot()
    ) {
        self.bufferPoolUnderflows = bufferPoolUnderflows
        self.callbackTiming = callbackTiming
        self.cacheMetrics = cacheMetrics
    }
}

public enum AudioCacheKind: String, Sendable, Hashable, Codable {
    case pcm
    case waveform
    case analysis
    case proxy
}

public struct AudioCacheMetricsSnapshot: Sendable, Hashable, Codable {
    public var hits: UInt64
    public var misses: UInt64
    public var hitsByKind: [AudioCacheKind: UInt64]
    public var missesByKind: [AudioCacheKind: UInt64]

    public init(
        hits: UInt64 = 0,
        misses: UInt64 = 0,
        hitsByKind: [AudioCacheKind: UInt64] = [:],
        missesByKind: [AudioCacheKind: UInt64] = [:]
    ) {
        self.hits = hits
        self.misses = misses
        self.hitsByKind = hitsByKind
        self.missesByKind = missesByKind
    }
}

/// Phase 1 cache metrics collector.
///
/// Important: this is NOT realtime-safe yet (uses a lock). It is intended to be called from a
/// non-RT context (or via a future RT-safe proxy that batches updates).
public final class AudioCacheMetricsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: AudioCacheMetricsSnapshot

    public init(snapshot: AudioCacheMetricsSnapshot = AudioCacheMetricsSnapshot()) {
        self.snapshot = snapshot
    }

    public func recordHit(kind: AudioCacheKind) {
        lock.lock(); defer { lock.unlock() }
        snapshot.hits &+= 1
        snapshot.hitsByKind[kind, default: 0] &+= 1
    }

    public func recordMiss(kind: AudioCacheKind) {
        lock.lock(); defer { lock.unlock() }
        snapshot.misses &+= 1
        snapshot.missesByKind[kind, default: 0] &+= 1
    }

    public func snapshotAndReset() -> AudioCacheMetricsSnapshot {
        lock.lock(); defer { lock.unlock() }
        let out = snapshot
        snapshot = AudioCacheMetricsSnapshot()
        return out
    }

    public func snapshotOnly() -> AudioCacheMetricsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}

public struct AudioCallbackTimingSnapshot: Sendable, Hashable, Codable {
    /// Bucket upper bounds in nanoseconds (monotonic ascending).
    /// The last bucket represents "> lastBound".
    public var bucketUpperBoundsNanos: [UInt64]
    public var bucketCounts: [UInt64]

    public init(
        bucketUpperBoundsNanos: [UInt64] = [
            100_000,   // 0.1 ms
            250_000,   // 0.25 ms
            500_000,   // 0.5 ms
            1_000_000, // 1 ms
            2_000_000, // 2 ms
            5_000_000, // 5 ms
            10_000_000 // 10 ms
        ],
        bucketCounts: [UInt64]? = nil
    ) {
        self.bucketUpperBoundsNanos = bucketUpperBoundsNanos
        let n = bucketUpperBoundsNanos.count + 1
        if let bucketCounts {
            self.bucketCounts = bucketCounts.count == n ? bucketCounts : Array(repeating: 0, count: n)
        } else {
            self.bucketCounts = Array(repeating: 0, count: n)
        }
    }
}

/// Phase 1 callback timing collector.
///
/// Important: this is NOT realtime-safe yet (uses a lock). It is intended to be called from a
/// non-RT context (or via a future RT-safe proxy that batches updates).
public final class AudioCallbackTimingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: AudioCallbackTimingSnapshot

    public init(snapshot: AudioCallbackTimingSnapshot = AudioCallbackTimingSnapshot()) {
        self.snapshot = snapshot
    }

    public func record(durationNanos: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let idx = Self.bucketIndex(durationNanos: durationNanos, bounds: snapshot.bucketUpperBoundsNanos)
        snapshot.bucketCounts[idx] &+= 1
    }

    public func snapshotAndReset() -> AudioCallbackTimingSnapshot {
        lock.lock(); defer { lock.unlock() }
        let out = snapshot
        snapshot.bucketCounts = Array(repeating: 0, count: snapshot.bucketCounts.count)
        return out
    }

    public func snapshotOnly() -> AudioCallbackTimingSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    static func bucketIndex(durationNanos: UInt64, bounds: [UInt64]) -> Int {
        for (i, upper) in bounds.enumerated() {
            if durationNanos <= upper { return i }
        }
        return bounds.count
    }
}

/// A stable identifier for an audio source binding (decode/cache handle).
///
/// This is intentionally opaque: MediaIO/decoders own the underlying resources.
public struct AudioSourceHandle: Codable, Sendable, Hashable {
    public var id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Binds graph `.source` nodes to decoder/cache handles.
///
/// - Must be deterministic for the same inputs (or include versioning in the handle id).
/// - Must be safe to call off the realtime audio thread.
public protocol AudioResourceBinder: Sendable {
    func bindSource(
        clipId: UUID,
        assetId: UUID,
        formatHint: AudioSourceFormat?,
        quality: AudioRenderQuality
    ) -> AudioSourceHandle?
}

public struct AudioSourceFormat: Codable, Sendable, Hashable {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
    }
}

/// Interleaved float32 PCM.
///
/// This is intentionally a simple value type for Phase 1 skeleton.
public struct AudioPCMBlock: Sendable, Equatable {
    public var channelCount: Int
    public var frameCount: Int

    /// Interleaved samples: [L0, R0, L1, R1, ...] when channelCount == 2.
    public var interleaved: [Float]

    public init(channelCount: Int, frameCount: Int, interleaved: [Float]) {
        self.channelCount = max(1, channelCount)
        self.frameCount = max(0, frameCount)
        self.interleaved = interleaved
    }

    public static func silence(channelCount: Int, frameCount: Int) -> AudioPCMBlock {
        let c = max(1, channelCount)
        let n = max(0, frameCount)
        return AudioPCMBlock(channelCount: c, frameCount: n, interleaved: Array(repeating: 0, count: c * n))
    }
}

// MARK: - Fixed-capacity buffers (realtime path)

public final class AudioBuffer: @unchecked Sendable {
    public let channelCount: Int
    public let capacityFrames: Int

    // Internal pool tags used by RT-safe pools to recycle without allocations.
    // (-1 means "not from a tagged pool"; -2 used for shared empty buffers)
    var _poolChannelIndex: Int = -1
    var _poolSlotIndex: Int = -1

    /// Current valid frames in this buffer.
    public var frameCount: Int

    /// Interleaved storage sized to `channelCount * capacityFrames`.
    public var interleaved: [Float]

    public init(channelCount: Int, capacityFrames: Int) {
        self.channelCount = max(1, channelCount)
        self.capacityFrames = max(0, capacityFrames)
        self.frameCount = 0
        self.interleaved = Array(repeating: 0, count: self.channelCount * self.capacityFrames)
    }

    public func zeroFill(frames: Int) {
        let frames = min(max(0, frames), capacityFrames)
        frameCount = frames
        let n = frames * channelCount
        if n > 0 {
            interleaved.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress?.initialize(repeating: 0, count: n)
            }
        }
    }
}

/// A borrowed buffer lease.
///
/// The caller must return it to the pool via `AudioBufferPool.recycle(_:)`.
public struct AudioBufferLease: @unchecked Sendable, Hashable {
    public var buffer: AudioBuffer

    public init(buffer: AudioBuffer) {
        self.buffer = buffer
    }

    public static func == (lhs: AudioBufferLease, rhs: AudioBufferLease) -> Bool {
        ObjectIdentifier(lhs.buffer) == ObjectIdentifier(rhs.buffer)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(buffer))
    }
}

public protocol AudioBufferPool: Sendable {
    /// Borrow a fixed-capacity interleaved buffer.
    ///
    /// Note: Phase 1 default pool is *not* realtime-safe yet; the interface is.
    func borrow(channelCount: Int, frameCount: Int) -> AudioBufferLease

    /// Return a previously borrowed lease.
    func recycle(_ lease: AudioBufferLease)
}

/// Phase 1 pool implementation: fixed-capacity buffers + a simple freelist.
///
/// This is designed for correctness and determinism; a lock-free RT-safe pool can replace it later
/// without changing the public interfaces.
public final class FixedAudioBufferPool: @unchecked Sendable, AudioBufferPool {
    private let capacityFrames: Int
    private let maxBuffersPerChannelCount: Int

    private let lock = NSLock()
    private var free: [Int: [AudioBuffer]] = [:]
    private var underflows: UInt64 = 0

    public init(capacityFrames: Int, maxBuffersPerChannelCount: Int = 16) {
        self.capacityFrames = max(0, capacityFrames)
        self.maxBuffersPerChannelCount = max(1, maxBuffersPerChannelCount)
    }

    public func borrow(channelCount: Int, frameCount: Int) -> AudioBufferLease {
        let c = max(1, channelCount)
        let requested = max(0, frameCount)

        let buf: AudioBuffer = {
            lock.lock(); defer { lock.unlock() }
            if var list = free[c], !list.isEmpty {
                let b = list.removeLast()
                free[c] = list
                return b
            }
            underflows &+= 1
            return AudioBuffer(channelCount: c, capacityFrames: capacityFrames)
        }()

        buf.zeroFill(frames: min(requested, buf.capacityFrames))

        return AudioBufferLease(buffer: buf)
    }

    public func recycle(_ lease: AudioBufferLease) {
        let c = lease.buffer.channelCount
        lock.lock(); defer { lock.unlock() }
        var list = free[c, default: []]
        if list.count < maxBuffersPerChannelCount {
            list.append(lease.buffer)
            free[c] = list
        }
    }

    public func diagnosticsSnapshot() -> AudioDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return AudioDiagnostics(bufferPoolUnderflows: underflows)
    }
}

/// A pool that preallocates a fixed number of buffers per channelCount and never grows.
///
/// This is *not* realtime-safe yet because it uses a lock, but it is allocation-free after init.
public final class PreallocatedAudioBufferPool: @unchecked Sendable, AudioBufferPool {
    private let capacityFrames: Int
    private let supportedChannelCounts: [Int]

    private let lock = NSLock()
    private var free: [Int: [AudioBuffer]] = [:]
    private var emptyByChannel: [Int: AudioBuffer] = [:]
    private var underflows: UInt64 = 0

    public init(capacityFrames: Int, supportedChannelCounts: [Int] = [1, 2], buffersPerChannelCount: Int = 16) {
        self.capacityFrames = max(0, capacityFrames)
        self.supportedChannelCounts = supportedChannelCounts.map { max(1, $0) }

        for c in self.supportedChannelCounts {
            free[c] = (0..<max(1, buffersPerChannelCount)).map { _ in
                AudioBuffer(channelCount: c, capacityFrames: self.capacityFrames)
            }
            emptyByChannel[c] = AudioBuffer(channelCount: c, capacityFrames: 0)
        }
    }

    public func borrow(channelCount: Int, frameCount: Int) -> AudioBufferLease {
        let c = max(1, channelCount)
        let requested = max(0, frameCount)

        lock.lock(); defer { lock.unlock() }
        guard var list = free[c], let buf = list.popLast() else {
            // No-growth policy: return a preallocated empty buffer (frameCount=0) and count an underflow.
            underflows &+= 1
            let empty = emptyByChannel[c] ?? AudioBuffer(channelCount: c, capacityFrames: 0)
            empty.frameCount = 0
            return AudioBufferLease(buffer: empty)
        }
        free[c] = list
        buf.zeroFill(frames: min(requested, buf.capacityFrames))
        return AudioBufferLease(buffer: buf)
    }

    public func recycle(_ lease: AudioBufferLease) {
        let c = lease.buffer.channelCount
        lock.lock(); defer { lock.unlock() }
        guard supportedChannelCounts.contains(c) else { return }
        // Do not recycle shared empty buffers.
        if emptyByChannel[c] === lease.buffer { return }
        free[c, default: []].append(lease.buffer)
    }

    public func diagnosticsSnapshot() -> AudioDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return AudioDiagnostics(bufferPoolUnderflows: underflows)
    }
}

/// Realtime-safe (Phase 2) pool: preallocated fixed-capacity buffers + lock-free freelist.
///
/// - No locks.
/// - No allocations after init.
/// - Exhaustion behavior: returns a preallocated empty buffer (frameCount=0) and increments an
///   atomic underflow counter.
public final class RealtimeAudioBufferPool: @unchecked Sendable, AudioBufferPool {
    private final class ChannelPool {
        let channelCount: Int
        let buffers: [AudioBuffer]
        let empty: AudioBuffer

        // Head index into `buffers`, or -1 when empty.
        let head: ManagedAtomic<Int>
        // next[i] is the next index for buffers[i] when it is on the free stack.
        let next: [ManagedAtomic<Int>]

        init(channelCount: Int, capacityFrames: Int, buffersPerChannelCount: Int, channelIndex: Int) {
            self.channelCount = max(1, channelCount)

            let n = max(0, buffersPerChannelCount)
            var bufs: [AudioBuffer] = []
            bufs.reserveCapacity(n)
            for i in 0..<n {
                let b = AudioBuffer(channelCount: self.channelCount, capacityFrames: capacityFrames)
                b._poolChannelIndex = channelIndex
                b._poolSlotIndex = i
                bufs.append(b)
            }
            self.buffers = bufs

            let e = AudioBuffer(channelCount: self.channelCount, capacityFrames: 0)
            e._poolChannelIndex = channelIndex
            e._poolSlotIndex = -2
            self.empty = e

            var nextAtoms: [ManagedAtomic<Int>] = []
            nextAtoms.reserveCapacity(n)
            if n > 0 {
                for i in 0..<(n - 1) {
                    nextAtoms.append(ManagedAtomic(i + 1))
                }
                nextAtoms.append(ManagedAtomic(-1))
                self.head = ManagedAtomic(0)
            } else {
                self.head = ManagedAtomic(-1)
            }
            self.next = nextAtoms
        }

        func pop() -> AudioBuffer? {
            while true {
                let oldHead = head.load(ordering: .acquiring)
                if oldHead < 0 { return nil }
                let nextIndex = next[oldHead].load(ordering: .relaxed)
                let r = head.compareExchange(
                    expected: oldHead,
                    desired: nextIndex,
                    successOrdering: .acquiringAndReleasing,
                    failureOrdering: .acquiring
                )
                if r.exchanged {
                    return buffers[oldHead]
                }
            }
        }

        func push(slotIndex: Int) {
            while true {
                let oldHead = head.load(ordering: .acquiring)
                next[slotIndex].store(oldHead, ordering: .relaxed)
                let r = head.compareExchange(
                    expected: oldHead,
                    desired: slotIndex,
                    successOrdering: .acquiringAndReleasing,
                    failureOrdering: .acquiring
                )
                if r.exchanged { return }
            }
        }
    }

    private let capacityFrames: Int
    private let channelPools: [ChannelPool]
    private let underflows: ManagedAtomic<UInt64>
    private let maxFallbackChannelCount: Int
    private let emptyFallbackByChannelCount: [AudioBuffer]

    public init(capacityFrames: Int, supportedChannelCounts: [Int] = [1, 2], buffersPerChannelCount: Int = 16) {
        self.capacityFrames = max(0, capacityFrames)

        var pools: [ChannelPool] = []
        let counts = supportedChannelCounts.map { max(1, $0) }
        let maxC = max(1, counts.max() ?? 1)
        self.maxFallbackChannelCount = maxC

        var empties: [AudioBuffer] = []
        empties.reserveCapacity(maxC + 1)
        // index 0 unused
        empties.append(AudioBuffer(channelCount: 1, capacityFrames: 0))
        empties[0]._poolChannelIndex = -1
        empties[0]._poolSlotIndex = -2
        if maxC >= 1 {
            for c in 1...maxC {
                let e = AudioBuffer(channelCount: c, capacityFrames: 0)
                e._poolChannelIndex = -1
                e._poolSlotIndex = -2
                empties.append(e)
            }
        }
        self.emptyFallbackByChannelCount = empties

        pools.reserveCapacity(counts.count)
        for (idx, c) in counts.enumerated() {
            pools.append(ChannelPool(
                channelCount: c,
                capacityFrames: self.capacityFrames,
                buffersPerChannelCount: max(0, buffersPerChannelCount),
                channelIndex: idx
            ))
        }
        self.channelPools = pools
        self.underflows = ManagedAtomic(0)
    }

    public func borrow(channelCount: Int, frameCount: Int) -> AudioBufferLease {
        let c = max(1, channelCount)
        let requested = max(0, frameCount)
        guard let pool = poolForChannelCount(c) else {
            underflows.wrappingIncrement(ordering: .relaxed)
            let clamped = min(c, maxFallbackChannelCount)
            return AudioBufferLease(buffer: emptyFallbackByChannelCount[clamped])
        }

        guard let buf = pool.pop() else {
            underflows.wrappingIncrement(ordering: .relaxed)
            // Shared empty buffer; never mutated.
            return AudioBufferLease(buffer: pool.empty)
        }

        buf.zeroFill(frames: min(requested, buf.capacityFrames))
        return AudioBufferLease(buffer: buf)
    }

    public func recycle(_ lease: AudioBufferLease) {
        let b = lease.buffer
        let channelIndex = b._poolChannelIndex
        let slot = b._poolSlotIndex
        guard channelIndex >= 0, channelIndex < channelPools.count else { return }
        guard slot >= 0 else { return } // ignore shared empty buffers / foreign buffers
        channelPools[channelIndex].push(slotIndex: slot)
    }

    public func diagnosticsSnapshot() -> AudioDiagnostics {
        let u = underflows.load(ordering: .relaxed)
        return AudioDiagnostics(bufferPoolUnderflows: u)
    }

    private func poolForChannelCount(_ c: Int) -> ChannelPool? {
        // Small list; linear scan avoids Dictionary allocations/locks.
        for p in channelPools {
            if p.channelCount == c { return p }
        }
        return nil
    }
}
