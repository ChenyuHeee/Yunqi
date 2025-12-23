import AudioEngine
import EditorCore
import Foundation

public struct AudioGraphDump: Sendable, Codable, Hashable {
    public var schemaVersion: Int
    public var graph: Graph
    public var plan: Plan?

    public init(schemaVersion: Int = 1, graph: Graph, plan: Plan? = nil) {
        self.schemaVersion = schemaVersion
        self.graph = graph
        self.plan = plan
    }

    public init(graph: AudioGraph, plan: AudioRenderPlan? = nil) {
        self.schemaVersion = 1
        self.graph = Graph(graph)
        self.plan = plan.map { Plan($0) }
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

    // MARK: - Nested representations (stable ordering)

    public struct Graph: Sendable, Codable, Hashable {
        public var version: Int
        public var nodes: [Node]
        public var edges: [Edge]
        public var outputs: Outputs
        public var parameterSnapshot: ParameterSnapshot?

        public init(version: Int, nodes: [Node], edges: [Edge], outputs: Outputs, parameterSnapshot: ParameterSnapshot? = nil) {
            self.version = version
            self.nodes = nodes
            self.edges = edges
            self.outputs = outputs
            self.parameterSnapshot = parameterSnapshot
        }

        public init(_ g: AudioGraph) {
            version = g.version
            nodes = g.nodes
                .map { Node(id: $0.key, spec: $0.value) }
                .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }

            edges = g.edges
                .map { Edge(from: $0.from, to: $0.to) }
                .sorted {
                    let af = $0.from.rawValue.uuidString
                    let bf = $1.from.rawValue.uuidString
                    if af != bf { return af < bf }
                    return $0.to.rawValue.uuidString < $1.to.rawValue.uuidString
                }

            outputs = Outputs(main: g.outputs.main)
            parameterSnapshot = g.parameterSnapshot.map(ParameterSnapshot.init)
        }
    }

    public struct ParameterSnapshot: Sendable, Codable, Hashable {
        public var timeSeconds: Double
        public var clips: [Clip]

        public init(timeSeconds: Double, clips: [Clip]) {
            self.timeSeconds = timeSeconds
            self.clips = clips
        }

        public init(_ s: AudioGraphParameterSnapshot) {
            timeSeconds = s.timeSeconds
            clips = s.clips
                .map(Clip.init)
                .sorted {
                    let a = $0.clipId.uuidString
                    let b = $1.clipId.uuidString
                    if a != b { return a < b }
                    let at = $0.trackId.uuidString
                    let bt = $1.trackId.uuidString
                    if at != bt { return at < bt }
                    return $0.busId.uuidString < $1.busId.uuidString
                }
        }
    }

    public struct Clip: Sendable, Codable, Hashable {
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

        public init(_ c: AudioClipParameterSnapshot) {
            clipId = c.clipId
            trackId = c.trackId
            busId = c.busId
            role = c.role
            isMuted = c.isMuted
            effectiveGain = c.effectiveGain
            effectivePan = c.effectivePan
        }
    }

    public struct Node: Sendable, Codable, Hashable {
        public var id: AudioNodeID
        public var spec: AudioNodeSpec

        public init(id: AudioNodeID, spec: AudioNodeSpec) {
            self.id = id
            self.spec = spec
        }
    }

    public struct Edge: Sendable, Codable, Hashable {
        public var from: AudioNodeID
        public var to: AudioNodeID

        public init(from: AudioNodeID, to: AudioNodeID) {
            self.from = from
            self.to = to
        }
    }

    public struct Outputs: Sendable, Codable, Hashable {
        public var main: AudioNodeID?

        public init(main: AudioNodeID? = nil) {
            self.main = main
        }
    }

    public struct Plan: Sendable, Codable, Hashable {
        public var quality: AudioRenderQuality
        public var stableHash64: UInt64
        public var ordered: [PlannedNode]
        public var diagnostics: Diagnostics

        public init(quality: AudioRenderQuality, stableHash64: UInt64, ordered: [PlannedNode], diagnostics: Diagnostics) {
            self.quality = quality
            self.stableHash64 = stableHash64
            self.ordered = ordered
            self.diagnostics = diagnostics
        }

        public init(_ p: AudioRenderPlan) {
            quality = p.quality
            stableHash64 = p.stableHash64
            ordered = p.ordered.map { PlannedNode($0) }
            diagnostics = Diagnostics(p.diagnostics)
        }
    }

    public struct PlannedNode: Sendable, Codable, Hashable {
        public var id: AudioNodeID
        public var spec: AudioNodeSpec
        public var inputs: [AudioNodeID]
        public var boundSourceId: UUID?

        public init(id: AudioNodeID, spec: AudioNodeSpec, inputs: [AudioNodeID], boundSourceId: UUID? = nil) {
            self.id = id
            self.spec = spec
            self.inputs = inputs
            self.boundSourceId = boundSourceId
        }

        public init(_ n: AudioPlannedNode) {
            id = n.id
            spec = n.spec
            inputs = n.inputs
            boundSourceId = n.boundSource?.id
        }
    }

    public struct Diagnostics: Sendable, Codable, Hashable {
        public var issues: [Issue]

        public init(issues: [Issue] = []) {
            self.issues = issues
        }

        public init(_ d: AudioGraphCompileDiagnostics) {
            issues = d.issues.map(Issue.init)
        }
    }

    public enum Issue: Sendable, Codable, Hashable {
        case missingNode(node: String)
        case danglingMainOutput(node: String)
        case cycleDetected(remaining: [String])
        case unboundSource(node: String, clipId: String, assetId: String)

        public init(_ i: AudioGraphCompileIssue) {
            switch i {
            case let .missingNode(id):
                self = .missingNode(node: id.rawValue.uuidString)
            case let .danglingMainOutput(id):
                self = .danglingMainOutput(node: id.rawValue.uuidString)
            case let .cycleDetected(remaining):
                self = .cycleDetected(remaining: remaining.map { $0.rawValue.uuidString }.sorted())
            case let .unboundSource(node, clipId, assetId):
                self = .unboundSource(node: node.rawValue.uuidString, clipId: clipId.uuidString, assetId: assetId.uuidString)
            }
        }
    }
}
