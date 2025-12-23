import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import CoreVideo
import Metal
import MetalKit

public final class MetalVideoCompositor: NSObject, AVVideoCompositing {
    private let renderingQueue = DispatchQueue(label: "yunqi.renderengine.metalvideocompositor.render")
    private let renderContextQueue = DispatchQueue(label: "yunqi.renderengine.metalvideocompositor.context")

    private var renderContext: AVVideoCompositionRenderContext?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private var textureCache: CVMetalTextureCache?

    private var didLogGeometryOnce: Bool = false
    private var didDumpFrameOnce: Bool = false

    private static let isGeometryDebugEnabled: Bool = {
        ProcessInfo.processInfo.environment["YUNQI_METAL_COMPOSITOR_DEBUG"] == "1"
    }()

    private static let shouldDumpFirstFrame: Bool = {
        ProcessInfo.processInfo.environment["YUNQI_DUMP_COMPOSITOR_FRAME"] == "1"
    }()

    private static let dumpCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: nil)
    }()
    private static let isDebugLoggingEnabled: Bool = {
        let v = ProcessInfo.processInfo.environment["YUNQI_METAL_COMPOSITOR_LOG"]?.lowercased()
        return v == "1" || v == "true" || v == "yes"
    }()

    private var cancellationToken: UInt64 = 0

    private struct SendableOpaquePointer: @unchecked Sendable {
        let raw: UnsafeMutableRawPointer
    }

    public override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue")
        }
        self.commandQueue = commandQueue

        let metalSource = Self.metalShaderSource
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: metalSource, options: nil)
        } catch {
            fatalError("Failed to compile Metal shader library: \(error)")
        }

        guard let v = library.makeFunction(name: "yunqi_compositor_vertex"),
              let f = library.makeFunction(name: "yunqi_compositor_fragment")
        else {
            fatalError("Missing Metal shader functions")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = v
        desc.fragmentFunction = f
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        // We output premultiplied colors (rgb already multiplied by alpha/opacity).
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Failed to create Metal pipeline state: \(error)")
        }

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        self.samplerState = device.makeSamplerState(descriptor: sampDesc)!

        super.init()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache
    }

    // MARK: - AVVideoCompositing

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: ([String: any Sendable]())
        ]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: ([String: any Sendable]())
        ]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContextQueue.sync {
            renderContext = newRenderContext
        }
    }

    public func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        let token = renderContextQueue.sync { cancellationToken }

        renderingQueue.async { [weak self] in
            guard let self else { return }
            if self.renderContextQueue.sync(execute: { self.cancellationToken }) != token {
                asyncVideoCompositionRequest.finishCancelledRequest()
                return
            }

            guard let ctx = self.renderContextQueue.sync(execute: { self.renderContext }) else {
                asyncVideoCompositionRequest.finish(with: NSError(domain: "yunqi.renderengine", code: -2))
                return
            }

            guard let dstPB = ctx.newPixelBuffer() else {
                asyncVideoCompositionRequest.finish(with: NSError(domain: "yunqi.renderengine", code: -3))
                return
            }

            guard let dstTex = self.makeTexture(from: dstPB, pixelFormat: .bgra8Unorm) else {
                asyncVideoCompositionRequest.finish(with: NSError(domain: "yunqi.renderengine", code: -4))
                return
            }

            let dstPBPtr = SendableOpaquePointer(raw: Unmanaged.passRetained(dstPB).toOpaque())

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = dstTex
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

            guard let commandBuffer = self.commandQueue.makeCommandBuffer() else {
                asyncVideoCompositionRequest.finish(with: NSError(domain: "yunqi.renderengine", code: -5))
                return
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                asyncVideoCompositionRequest.finish(with: NSError(domain: "yunqi.renderengine", code: -6))
                return
            }

            encoder.setRenderPipelineState(self.pipelineState)
            encoder.setFragmentSamplerState(self.samplerState, index: 0)

            let time = asyncVideoCompositionRequest.compositionTime
            let renderSize = ctx.size

            let instruction = asyncVideoCompositionRequest.videoCompositionInstruction
            let layerInstructions: [AVVideoCompositionLayerInstruction] = {
                // AVFoundation often supplies an immutable AVVideoCompositionInstruction at runtime,
                // even if we built AVMutableVideoCompositionInstruction.
                if let i = instruction as? AVVideoCompositionInstruction {
                    return i.layerInstructions
                }
                if let i = instruction as? AVMutableVideoCompositionInstruction {
                    return i.layerInstructions
                }
                return []
            }()

            if Self.isDebugLoggingEnabled {
                NSLog(
                    "[MetalVideoCompositor] t=%.3fs instruction=%@ layers=%d",
                    time.seconds,
                    String(describing: type(of: instruction)),
                    layerInstructions.count
                )
            }

            if !layerInstructions.isEmpty {
                for li in layerInstructions {
                    let trackID = li.trackID
                    guard let srcPB = asyncVideoCompositionRequest.sourceFrame(byTrackID: trackID) else {
                        continue
                    }

                    if Self.isDebugLoggingEnabled {
                        let fmt = CVPixelBufferGetPixelFormatType(srcPB)
                        NSLog("[MetalVideoCompositor] trackID=%d srcPixFmt=0x%08x", trackID, fmt)
                    }

                    var opacityStart: Float = 1
                    var opacityEnd: Float = 1
                    var opacityTR = CMTimeRange.invalid
                    _ = li.getOpacityRamp(for: time, startOpacity: &opacityStart, endOpacity: &opacityEnd, timeRange: &opacityTR)
                    let opacity = opacityStart
                    if opacity <= 0.0001 {
                        continue
                    }

                    var t0 = CGAffineTransform.identity
                    var t1 = CGAffineTransform.identity
                    var tr = CMTimeRange.invalid
                    let hasTransform = li.getTransformRamp(for: time, start: &t0, end: &t1, timeRange: &tr)
                    let transform = hasTransform ? t0 : .identity

                    if Self.isGeometryDebugEnabled {
                        let shouldLog = self.renderContextQueue.sync { () -> Bool in
                            if self.didLogGeometryOnce { return false }
                            self.didLogGeometryOnce = true
                            return true
                        }
                        if shouldLog {
                            let w = CVPixelBufferGetWidth(srcPB)
                            let h = CVPixelBufferGetHeight(srcPB)
                            let p00 = CGPoint(x: 0, y: 0).applying(transform)
                            let p10 = CGPoint(x: w, y: 0).applying(transform)
                            let p01 = CGPoint(x: 0, y: h).applying(transform)
                            let p11 = CGPoint(x: w, y: h).applying(transform)
                            let minX = [p00.x, p10.x, p01.x, p11.x].min() ?? 0
                            let maxX = [p00.x, p10.x, p01.x, p11.x].max() ?? 0
                            let minY = [p00.y, p10.y, p01.y, p11.y].min() ?? 0
                            let maxY = [p00.y, p10.y, p01.y, p11.y].max() ?? 0

                            NSLog(
                                "[MetalVideoCompositor] t=%.3fs trackID=%d src=%dx%d render=%.0fx%.0f hasT=%@ T=[%.3f %.3f %.3f %.3f %.3f %.3f] bbox=(%.1f,%.1f)-(%.1f,%.1f)",
                                time.seconds,
                                trackID,
                                w,
                                h,
                                renderSize.width,
                                renderSize.height,
                                hasTransform ? "yes" : "no",
                                transform.a,
                                transform.b,
                                transform.c,
                                transform.d,
                                transform.tx,
                                transform.ty,
                                minX,
                                minY,
                                maxX,
                                maxY
                            )
                        }
                    }

                    guard let srcTex = self.makeTexture(from: srcPB, pixelFormat: .bgra8Unorm) else {
                        continue
                    }

                    let vertices = Self.makeQuadVertices(
                        srcWidth: CVPixelBufferGetWidth(srcPB),
                        srcHeight: CVPixelBufferGetHeight(srcPB),
                        renderWidth: Int(renderSize.width),
                        renderHeight: Int(renderSize.height),
                        transform: transform,
                        opacity: opacity
                    )

                    encoder.setVertexBytes(vertices, length: MemoryLayout<MetalVertex>.stride * vertices.count, index: 0)
                    encoder.setFragmentTexture(srcTex, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
                }
            }

            encoder.endEncoding()

            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self else { return }
                let dstPB = Unmanaged<CVPixelBuffer>.fromOpaque(dstPBPtr.raw).takeRetainedValue()

                if Self.shouldDumpFirstFrame {
                    let shouldDump = self.renderContextQueue.sync { () -> Bool in
                        if self.didDumpFrameOnce { return false }
                        self.didDumpFrameOnce = true
                        return true
                    }
                    if shouldDump {
                        let url = URL(fileURLWithPath: "/tmp/yunqi-compositor-frame.png")
                        NSLog("[MetalVideoCompositor] dumping first frame to %@", url.path)
                        let ci = CIImage(cvPixelBuffer: dstPB)
                        guard let cg = Self.dumpCIContext.createCGImage(ci, from: ci.extent) else {
                            NSLog("[MetalVideoCompositor] dump failed: createCGImage returned nil extent=%@", NSStringFromRect(ci.extent))
                            return
                        }

                        guard let data = CFDataCreateMutable(nil, 0) else {
                            NSLog("[MetalVideoCompositor] dump failed: CFDataCreateMutable nil")
                            return
                        }
                        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                            NSLog("[MetalVideoCompositor] dump failed: CGImageDestinationCreateWithData nil")
                            return
                        }
                        CGImageDestinationAddImage(dest, cg, nil)
                        guard CGImageDestinationFinalize(dest) else {
                            NSLog("[MetalVideoCompositor] dump failed: CGImageDestinationFinalize=false")
                            return
                        }
                        do {
                            try (data as Data).write(to: url, options: [.atomic])
                            NSLog("[MetalVideoCompositor] dumped first frame: %@", url.path)
                        } catch {
                            NSLog("[MetalVideoCompositor] dump failed: write error=%@", String(describing: error))
                        }
                    }
                }

                let stillSame = self.renderContextQueue.sync { self.cancellationToken == token }
                if !stillSame {
                    asyncVideoCompositionRequest.finishCancelledRequest()
                    return
                }
                asyncVideoCompositionRequest.finish(withComposedVideoFrame: dstPB)
            }

            commandBuffer.commit()
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        renderContextQueue.sync {
            cancellationToken &+= 1
        }
        renderingQueue.async {
            if let cache = self.textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
        }
    }

    // MARK: - Helpers

    private func makeTexture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            return nil
        }
        return tex
    }

    private struct MetalVertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
        var opacity: Float
    }

    private static func makeQuadVertices(
        srcWidth: Int,
        srcHeight: Int,
        renderWidth: Int,
        renderHeight: Int,
        transform: CGAffineTransform,
        opacity: Float
    ) -> [MetalVertex] {
        func apply(_ p: CGPoint) -> CGPoint {
            p.applying(transform)
        }

        let p00 = apply(CGPoint(x: 0, y: 0))
        let p10 = apply(CGPoint(x: srcWidth, y: 0))
        let p01 = apply(CGPoint(x: 0, y: srcHeight))
        let p11 = apply(CGPoint(x: srcWidth, y: srcHeight))

        func toClip(_ p: CGPoint) -> SIMD2<Float> {
            let x = Float((p.x / CGFloat(max(1, renderWidth))) * 2.0 - 1.0)
            // AVVideoComposition transforms are typically authored in a top-left origin space
            // (Y increases downward). Flip Y when mapping into Metal clip space (Y up).
            let y = Float(1.0 - (p.y / CGFloat(max(1, renderHeight))) * 2.0)
            return SIMD2<Float>(x, y)
        }

        let v00 = MetalVertex(position: toClip(p00), texCoord: SIMD2<Float>(0, 0), opacity: opacity)
        let v10 = MetalVertex(position: toClip(p10), texCoord: SIMD2<Float>(1, 0), opacity: opacity)
        let v01 = MetalVertex(position: toClip(p01), texCoord: SIMD2<Float>(0, 1), opacity: opacity)
        let v11 = MetalVertex(position: toClip(p11), texCoord: SIMD2<Float>(1, 1), opacity: opacity)

        return [v00, v10, v01, v10, v11, v01]
    }
}

// AVFoundation annotates AVVideoCompositing as sendable; our internal state is protected by queues.
extension MetalVideoCompositor: @unchecked Sendable {}

extension MetalVideoCompositor {
    private static let metalShaderSource: String = #"""
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 texCoord;
    float opacity;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float opacity;
};

vertex VertexOut yunqi_compositor_vertex(
    const device VertexIn* vertices [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    VertexIn vin = vertices[vid];
    VertexOut out;
    out.position = float4(vin.position, 0.0, 1.0);
    out.texCoord = vin.texCoord;
    out.opacity = vin.opacity;
    return out;
}

fragment float4 yunqi_compositor_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> src [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    // Use the same UV convention as the preview blit pipeline.
    // (0,0) maps to the top-left in our sampling convention.
    float2 uv = in.texCoord;
    float4 c = src.sample(s, uv);
    c.a *= in.opacity;
    c.rgb *= in.opacity;
    return c;
}
"""#
}
