import Foundation

public struct MediaAsset: Codable, Sendable {
    public var id: UUID
    public var originalURL: URL
    public var importedAt: Date

    public init(id: UUID = UUID(), originalURL: URL, importedAt: Date = Date()) {
        self.id = id
        self.originalURL = originalURL
        self.importedAt = importedAt
    }
}

public protocol MediaAnalyzer {
    func analyze(asset: MediaAsset) async throws -> MediaAnalysis
}

public struct MediaAnalysis: Codable, Sendable {
    public var durationSeconds: Double
    public var hasVideo: Bool
    public var hasAudio: Bool

    public init(durationSeconds: Double, hasVideo: Bool, hasAudio: Bool) {
        self.durationSeconds = durationSeconds
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
    }
}
