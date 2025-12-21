import Foundation
import EditorCore

public protocol ProjectStore {
    func save(_ project: Project, to url: URL) throws
    func load(from url: URL) throws -> Project
}

public final class JSONProjectStore: ProjectStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func save(_ project: Project, to url: URL) throws {
        let data = try encoder.encode(project)
        try data.write(to: url, options: [.atomic])
    }

    public func load(from url: URL) throws -> Project {
        let data = try Data(contentsOf: url)
        return try decoder.decode(Project.self, from: data)
    }
}
