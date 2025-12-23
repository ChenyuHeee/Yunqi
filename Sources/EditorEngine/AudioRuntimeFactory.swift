import AudioEngine
import Foundation

/// Bridges compiled `AudioRenderPlan` to runtime node instances.
///
/// Per docs/audio-todolist.md §14.4: keep runtime implementation swappable without changing graph semantics.
public protocol AudioRuntimeFactory: Sendable {
    func makeRuntime(for plannedNode: AudioPlannedNode) throws -> any AudioNodeRuntime
}

public struct AudioRuntimeGraph: Sendable {
    public var ordered: [AudioPlannedNode]
    public var runtimes: [AudioNodeID: any AudioNodeRuntime]

    public init(ordered: [AudioPlannedNode], runtimes: [AudioNodeID: any AudioNodeRuntime]) {
        self.ordered = ordered
        self.runtimes = runtimes
    }
}

public enum AudioRuntimeBuildError: Error, Sendable {
    case missingRuntime(AudioNodeID)
}

public extension AudioRenderPlan {
    func buildRuntimeGraph(factory: any AudioRuntimeFactory) throws -> AudioRuntimeGraph {
        var map: [AudioNodeID: any AudioNodeRuntime] = [:]
        for node in ordered {
            map[node.id] = try factory.makeRuntime(for: node)
        }
        return AudioRuntimeGraph(ordered: ordered, runtimes: map)
    }
}
