import Foundation

public enum RenderQuality: String, Sendable {
    case realtime
    case high
}

public struct RenderRequest: Sendable {
    public var timeSeconds: Double
    public var quality: RenderQuality

    public init(timeSeconds: Double, quality: RenderQuality) {
        self.timeSeconds = timeSeconds
        self.quality = quality
    }
}

public struct RenderedFrame: Sendable {
    public var timeSeconds: Double
    public var width: Int
    public var height: Int
    /// RGBA8 premultiplied-last，长度应为 width*height*4。
    public var rgba: Data

    public init(timeSeconds: Double, width: Int, height: Int, rgba: Data) {
        self.timeSeconds = timeSeconds
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

public protocol RenderEngine: Sendable {
    func prepare() throws
    func renderFrame(_ request: RenderRequest) throws -> RenderedFrame
}

public final class NoopRenderEngine: RenderEngine, @unchecked Sendable {
    public init() {}

    public func prepare() throws {}

    public func renderFrame(_ request: RenderRequest) throws -> RenderedFrame {
        // Placeholder preview: a simple animated RGBA buffer.
        let width = 640
        let height = 360

        let t = request.timeSeconds
        let r = UInt8(clamping: Int((sin(t * 0.9) * 0.5 + 0.5) * 180 + 30))
        let g = UInt8(clamping: Int((sin(t * 1.3 + 1.0) * 0.5 + 0.5) * 180 + 30))
        let b = UInt8(clamping: Int((sin(t * 0.7 + 2.0) * 0.5 + 0.5) * 180 + 30))

        var bytes = [UInt8](repeating: 0, count: width * height * 4)

        let barX = Int(((sin(t * 1.1) * 0.5 + 0.5) * Double(width - 1)).rounded())
        let barHalfWidth = 3

        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let isBar = abs(x - barX) <= barHalfWidth

                bytes[i + 0] = isBar ? 240 : r
                bytes[i + 1] = isBar ? 240 : g
                bytes[i + 2] = isBar ? 240 : b
                bytes[i + 3] = 255
            }
        }

        return RenderedFrame(
            timeSeconds: request.timeSeconds,
            width: width,
            height: height,
            rgba: Data(bytes)
        )
    }
}
