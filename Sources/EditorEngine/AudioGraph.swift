import AudioEngine
import EditorCore
import Foundation

public struct AudioGraph: Sendable, Codable, Hashable {
    public var version: Int
    public var nodes: [AudioNodeID: AudioNodeSpec]
    public var edges: [AudioEdge]
    public var outputs: AudioGraphOutputs
    /// Optional parameter snapshot at the evaluation time.
    ///
    /// This is intended for diagnostics/golden tests and to keep a single source of truth
    /// for “what values were applied at time t”. Rendering semantics are still carried by nodes.
    public var parameterSnapshot: AudioGraphParameterSnapshot?

    public init(
        version: Int = 1,
        nodes: [AudioNodeID: AudioNodeSpec] = [:],
        edges: [AudioEdge] = [],
        outputs: AudioGraphOutputs = AudioGraphOutputs(),
        parameterSnapshot: AudioGraphParameterSnapshot? = nil
    ) {
        self.version = version
        self.nodes = nodes
        self.edges = edges
        self.outputs = outputs
        self.parameterSnapshot = parameterSnapshot
    }
}

public struct AudioGraphParameterSnapshot: Sendable, Codable, Hashable {
    public var timeSeconds: Double
    public var clips: [AudioClipParameterSnapshot]

    public init(timeSeconds: Double, clips: [AudioClipParameterSnapshot]) {
        self.timeSeconds = timeSeconds
        self.clips = clips
    }
}

public struct AudioClipParameterSnapshot: Sendable, Codable, Hashable {
    public var clipId: UUID
    public var trackId: UUID
    public var busId: UUID
    public var role: AudioRole?

    public var isMuted: Bool
    public var effectiveGain: Double
    public var effectivePan: Double

    public init(
        clipId: UUID,
        trackId: UUID,
        busId: UUID,
        role: AudioRole?,
        isMuted: Bool,
        effectiveGain: Double,
        effectivePan: Double
    ) {
        self.clipId = clipId
        self.trackId = trackId
        self.busId = busId
        self.role = role
        self.isMuted = isMuted
        self.effectiveGain = effectiveGain
        self.effectivePan = effectivePan
    }
}

public struct AudioNodeID: Sendable, Codable, Hashable, CustomStringConvertible {
    public var rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public struct AudioEdge: Sendable, Codable, Hashable {
    public var from: AudioNodeID
    public var to: AudioNodeID

    public init(from: AudioNodeID, to: AudioNodeID) {
        self.from = from
        self.to = to
    }
}

public struct AudioGraphOutputs: Sendable, Codable, Hashable {
    /// Main output node.
    public var main: AudioNodeID?

    /// Reserved for future: submix buses, stems, etc.
    public init(main: AudioNodeID? = nil) {
        self.main = main
    }
}

public enum AudioNodeSpec: Sendable, Codable, Hashable {
    case source(clipId: UUID, assetId: UUID, format: AudioSourceFormat?)
    /// Sample-accurate time mapping node.
    ///
    /// Semantics are defined by `AudioTimeMap` (timeline sampleTime -> source sampleTime).
    case timeMap(mode: AudioTimeStretchMode, map: AudioTimeMap)
    /// Clip-local fade envelope (Phase 1: semantic only).
    case fade(
        clipId: UUID,
        timelineStartSampleTime: Int64,
        timelineDurationSamples: Int64,
        fadeIn: AudioFadeSpec?,
        fadeOut: AudioFadeSpec?
    )
    case gain(value: Double)
    case pan(value: Double)
    case bus(id: UUID, role: AudioRole?)
    case meterTap
    case analyzerTap
}

public struct AudioFadeSpec: Sendable, Codable, Hashable {
    public var durationSamples: Int64
    public var shape: AudioFadeShape

    public init(durationSamples: Int64, shape: AudioFadeShape) {
        self.durationSamples = durationSamples
        self.shape = shape
    }
}

public enum AudioGraphCompileIssue: Sendable, Hashable {
    case missingNode(AudioNodeID)
    case danglingMainOutput(AudioNodeID)
    case cycleDetected(remaining: [AudioNodeID])
    case unboundSource(node: AudioNodeID, clipId: UUID, assetId: UUID)
}

public struct AudioGraphCompileDiagnostics: Sendable, Hashable {
    public var issues: [AudioGraphCompileIssue]

    public init(issues: [AudioGraphCompileIssue] = []) {
        self.issues = issues
    }

    public var isOK: Bool { issues.isEmpty }
}

public struct AudioPlannedNode: Sendable, Hashable {
    public var id: AudioNodeID
    public var spec: AudioNodeSpec
    public var inputs: [AudioNodeID]
    public var boundSource: AudioSourceHandle?

    public init(id: AudioNodeID, spec: AudioNodeSpec, inputs: [AudioNodeID], boundSource: AudioSourceHandle? = nil) {
        self.id = id
        self.spec = spec
        self.inputs = inputs
        self.boundSource = boundSource
    }
}

public struct StableHasher64 {
    private(set) var value: UInt64 = 0xcbf29ce484222325

    public init() {}

    public mutating func combine(bytes: UnsafeRawBufferPointer) {
        for b in bytes {
            value ^= UInt64(b)
            value &*= 0x00000100000001B3
        }
    }

    public mutating func combine(_ string: String) {
        string.utf8.withContiguousStorageIfAvailable { buf in
            combine(bytes: UnsafeRawBufferPointer(buf))
        } ?? {
            let arr = Array(string.utf8)
            arr.withUnsafeBytes { combine(bytes: $0) }
        }()
    }

    public mutating func combine(_ uuid: UUID) {
        var u = uuid.uuid
        withUnsafeBytes(of: &u) { combine(bytes: $0) }
    }

    public mutating func combine(_ int: Int) {
        var x = Int64(int)
        withUnsafeBytes(of: &x) { combine(bytes: $0) }
    }

    public mutating func combine(_ int64: Int64) {
        var x = int64
        withUnsafeBytes(of: &x) { combine(bytes: $0) }
    }

    public mutating func combine(_ uint64: UInt64) {
        var x = uint64
        withUnsafeBytes(of: &x) { combine(bytes: $0) }
    }

    public mutating func combine(_ double: Double) {
        var x = double.bitPattern
        withUnsafeBytes(of: &x) { combine(bytes: $0) }
    }
}

private extension AudioNodeSpec {
    func stableHash(into h: inout StableHasher64) {
        switch self {
        case let .source(clipId, assetId, format):
            h.combine("source")
            h.combine(clipId)
            h.combine(assetId)
            if let format {
                h.combine(format.sampleRate)
                h.combine(format.channelCount)
            } else {
                h.combine("nil")
            }
        case let .timeMap(mode, map):
            h.combine("timeMap")
            h.combine(mode.rawValue)
            h.combine(map.sampleRate)
            h.combine(map.timelineStartSampleTime)
            h.combine(map.timelineDurationSamples)
            h.combine(map.sourceInSampleTime)
            if let t = map.sourceTrim {
                h.combine(t.inSampleTime)
                h.combine(t.outSampleTime)
            } else {
                h.combine("nil")
            }
            h.combine(map.speed)
            h.combine(map.reverseMode.rawValue)
            if let loop = map.loop {
                h.combine(loop.startSampleTime)
                h.combine(loop.endSampleTime)
            } else {
                h.combine("nil")
            }
        case let .fade(clipId, timelineStartSampleTime, timelineDurationSamples, fadeIn, fadeOut):
            h.combine("fade")
            h.combine(clipId)
            h.combine(timelineStartSampleTime)
            h.combine(timelineDurationSamples)
            if let fadeIn {
                h.combine(fadeIn.durationSamples)
                h.combine(fadeIn.shape.rawValue)
            } else {
                h.combine("nil")
            }
            if let fadeOut {
                h.combine(fadeOut.durationSamples)
                h.combine(fadeOut.shape.rawValue)
            } else {
                h.combine("nil")
            }
        case let .gain(value):
            h.combine("gain")
            h.combine(value)
        case let .pan(value):
            h.combine("pan")
            h.combine(value)
        case let .bus(id, role):
            h.combine("bus")
            h.combine(id)
            h.combine(role?.name ?? "nil")
        case .meterTap:
            h.combine("meterTap")
        case .analyzerTap:
            h.combine("analyzerTap")
        }
    }
}

public struct AudioRenderPlan: Sendable, Hashable {
    public var quality: AudioRenderQuality
    public var planHash: Int

    /// Stable across processes/machines for cache keys.
    public var stableHash64: UInt64

    /// Deterministic topological order.
    public var ordered: [AudioPlannedNode]

    public var diagnostics: AudioGraphCompileDiagnostics

    public init(
        quality: AudioRenderQuality,
        planHash: Int,
        stableHash64: UInt64,
        ordered: [AudioPlannedNode],
        diagnostics: AudioGraphCompileDiagnostics
    ) {
        self.quality = quality
        self.planHash = planHash
        self.stableHash64 = stableHash64
        self.ordered = ordered
        self.diagnostics = diagnostics
    }
}

public struct AudioGraphCompiler: Sendable {
    public init() {}

    public func compile(graph: AudioGraph, quality: AudioRenderQuality) -> AudioRenderPlan {
        compile(graph: graph, quality: quality, binder: nil)
    }

    public func compile(
        graph: AudioGraph,
        quality: AudioRenderQuality,
        binder: (any AudioResourceBinder)?
    ) -> AudioRenderPlan {
        var issues: [AudioGraphCompileIssue] = []

        if let main = graph.outputs.main, graph.nodes[main] == nil {
            issues.append(.danglingMainOutput(main))
        }

        // Build adjacency and indegree, ignoring edges that reference missing nodes.
        var indegree: [AudioNodeID: Int] = [:]
        var outgoing: [AudioNodeID: [AudioNodeID]] = [:]
        var incoming: [AudioNodeID: [AudioNodeID]] = [:]

        for id in graph.nodes.keys {
            indegree[id] = 0
            outgoing[id] = []
            incoming[id] = []
        }

        var seenEdges = Set<AudioEdge>()
        for e in graph.edges {
            guard seenEdges.insert(e).inserted else { continue }
            guard graph.nodes[e.from] != nil else {
                issues.append(.missingNode(e.from))
                continue
            }
            guard graph.nodes[e.to] != nil else {
                issues.append(.missingNode(e.to))
                continue
            }

            outgoing[e.from, default: []].append(e.to)
            incoming[e.to, default: []].append(e.from)
            indegree[e.to, default: 0] += 1
        }

        func sortIDs(_ ids: [AudioNodeID]) -> [AudioNodeID] {
            ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        }

        // Prune nodes unreachable from main output (Phase 1 graph uses a single main output).
        // This keeps plan stable and avoids hashing irrelevant junk.
        let reachable: Set<AudioNodeID> = {
            guard let main = graph.outputs.main, graph.nodes[main] != nil else {
                return Set(graph.nodes.keys)
            }
            var stack: [AudioNodeID] = [main]
            var visited: Set<AudioNodeID> = []
            while let cur = stack.popLast() {
                guard visited.insert(cur).inserted else { continue }
                for src in incoming[cur] ?? [] {
                    stack.append(src)
                }
            }
            return visited
        }()

        // Restrict adjacency to reachable subgraph.
        if reachable.count != graph.nodes.count {
            indegree = indegree.filter { reachable.contains($0.key) }
            outgoing = outgoing.filter { reachable.contains($0.key) }
            incoming = incoming.filter { reachable.contains($0.key) }
            for (k, v) in outgoing {
                outgoing[k] = v.filter { reachable.contains($0) }
            }
            for (k, v) in incoming {
                incoming[k] = v.filter { reachable.contains($0) }
            }
            // Recompute indegree for reachable nodes.
            for id in indegree.keys {
                indegree[id] = 0
            }
            for (to, froms) in incoming {
                indegree[to] = froms.count
            }
        }

        // Kahn topological sort with deterministic tie-breaking.
        var ready = sortIDs(indegree.compactMap { (id, d) in d == 0 ? id : nil })
        var orderedIDs: [AudioNodeID] = []

        while let next = ready.first {
            ready.removeFirst()
            orderedIDs.append(next)
            for to in outgoing[next] ?? [] {
                let d = (indegree[to] ?? 0) - 1
                indegree[to] = d
                if d == 0 {
                    ready.append(to)
                    ready = sortIDs(ready)
                }
            }
        }

        if orderedIDs.count != indegree.count {
            let remaining = sortIDs(indegree.keys.filter { !Set(orderedIDs).contains($0) })
            issues.append(.cycleDetected(remaining: remaining))
            // In presence of cycles, still return a deterministic order: topo-order + remaining.
            orderedIDs.append(contentsOf: remaining)
        }

        var planned: [AudioPlannedNode] = orderedIDs.compactMap { id in
            guard let spec = graph.nodes[id] else { return nil }
            let ins = sortIDs(incoming[id] ?? [])
            return AudioPlannedNode(id: id, spec: spec, inputs: ins)
        }

        // Resource binding (Phase 1): bind `.source` nodes to decode/cache handles.
        if let binder {
            for i in 0..<planned.count {
                guard case let .source(clipId, assetId, format) = planned[i].spec else { continue }
                let handle = binder.bindSource(clipId: clipId, assetId: assetId, formatHint: format, quality: quality)
                planned[i].boundSource = handle
                if handle == nil {
                    issues.append(.unboundSource(node: planned[i].id, clipId: clipId, assetId: assetId))
                }
            }
        }

        // Node merge / constant fold (Phase 1): merge consecutive constant gains in linear chains.
        // This matches docs: "节点合并（例如连续 gain 合并）".
        if planned.count >= 2 {
            // Build quick lookup for current graph shape.
            var outCount: [AudioNodeID: Int] = [:]
            for n in planned {
                outCount[n.id] = 0
            }
            for n in planned {
                for input in n.inputs {
                    outCount[input, default: 0] += 1
                }
            }

            var byId: [AudioNodeID: AudioPlannedNode] = Dictionary(uniqueKeysWithValues: planned.map { ($0.id, $0) })

            for i in 0..<planned.count {
                let node = planned[i]
                guard case let .gain(v2) = node.spec else { continue }
                guard node.inputs.count == 1 else { continue }
                let parentId = node.inputs[0]
                guard outCount[parentId] == 1 else { continue }
                guard let parent = byId[parentId] else { continue }
                guard case let .gain(v1) = parent.spec else { continue }
                // Merge: parent gain absorbed into current gain.
                let merged = AudioPlannedNode(id: node.id, spec: .gain(value: v1 * v2), inputs: parent.inputs)
                planned[i] = merged
                byId[node.id] = merged
            }

            // Note: we keep the original parent nodes in `planned` for now.
            // The runtime can ignore them because they won't be referenced by merged nodes.
            // A later pass can remove unused nodes once we have a full node-type aware optimizer.
        }

        // Stable hash (cache-friendly) based on: version + quality + *compiled plan* nodes.
        var stable = StableHasher64()
        stable.combine(UInt64(graph.version))
        stable.combine(quality.rawValue)
        stable.combine(UInt64(planned.count))
        for n in planned {
            stable.combine(n.id.rawValue)
            n.spec.stableHash(into: &stable)
            stable.combine(UInt64(n.inputs.count))
            for input in n.inputs {
                stable.combine(input.rawValue)
            }
        }
        // Edge hashing is intentionally omitted from plan hash for Phase 1:
        // planned nodes already encode their inputs deterministically.

        // Keep existing Int hash for in-process usage/tests.
        var hasher = Hasher()
        hasher.combine(stable.value)
        let planHash = hasher.finalize()

        return AudioRenderPlan(
            quality: quality,
            planHash: planHash,
            stableHash64: stable.value,
            ordered: planned,
            diagnostics: AudioGraphCompileDiagnostics(issues: issues)
        )
    }
}
