import AppKit
import CoreImage
import Metal
import MetalKit
import SwiftUI

enum PreviewQuality: Sendable {
    case realtime
    case high
}

@MainActor
final class MetalPreviewRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    private var textureCache: CVMetalTextureCache?
    private var blitBGRAPipeline: MTLRenderPipelineState?
    private var blitYUVPipeline: MTLRenderPipelineState?
    private var blitSampler: MTLSamplerState?
    private var canvasBackgroundTexture: MTLTexture?
    private var canvasBackgroundBGRA: SIMD4<UInt8> = SIMD4<UInt8>(0, 0, 0, 255)

    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?
    private var preferredTransform: CGAffineTransform = .identity
    private var canvasSize: CGSize = .zero

    private static let isGeometryDebugEnabled: Bool = {
        ProcessInfo.processInfo.environment["YUNQI_METALPREVIEW_DEBUG"] == "1"
    }()

    init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device)

        super.init()

        // Best-effort setup; if this fails we still have the CIContext fallback.
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache

        let pipelines = Self.makeBlitPipelines(device: device, colorPixelFormat: mtkView.colorPixelFormat)
        self.blitBGRAPipeline = pipelines?.bgra
        self.blitYUVPipeline = pipelines?.yuv
        self.blitSampler = Self.makeBlitSampler(device: device)
        self.canvasBackgroundTexture = Self.makeSolidBGRA8Texture(device: device, b: 0, g: 0, r: 0, a: 255)

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.framebufferOnly = false
        mtkView.colorspace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        mtkView.drawableSize = mtkView.bounds.size
        mtkView.delegate = self
    }

    private static func windowBackgroundClearColor() -> MTLClearColor {
        let c = NSColor.windowBackgroundColor
        let srgb = c.usingColorSpace(.sRGB) ?? c
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return MTLClearColor(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }

    private static func makeSolidBGRA8Texture(device: MTLDevice, b: UInt8, g: UInt8, r: UInt8, a: UInt8) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var bytes: [UInt8] = [b, g, r, a]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
        return tex
    }

    private static func makeBlitSampler(device: MTLDevice) -> MTLSamplerState? {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: d)
    }

    private struct BlitPipelines {
        let bgra: MTLRenderPipelineState
        let yuv: MTLRenderPipelineState
    }

    private static func makeBlitPipelines(device: MTLDevice, colorPixelFormat: MTLPixelFormat) -> BlitPipelines? {
        // Minimal textured full-screen triangle pipelines, compiled at runtime.
        // This avoids adding a .metal file to the package for now.
        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct VSOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VSOut blitVS(uint vid [[vertex_id]]) {
            float2 pos;
            float2 uv;
            // Full-screen triangle with UV origin at top-left.
            // After clamping, in.uv=(0,0) samples top-left and in.uv=(1,1) samples bottom-right.
            if (vid == 0) { pos = float2(-1.0, -1.0); uv = float2(0.0, 1.0); }
            else if (vid == 1) { pos = float2( 3.0, -1.0); uv = float2(2.0, 1.0); }
            else { pos = float2(-1.0,  3.0); uv = float2(0.0, -1.0); }
            VSOut o;
            o.position = float4(pos, 0.0, 1.0);
            o.uv = uv;
            return o;
        }

        struct BlitParams {
            float3x3 uv;
        };

        fragment float4 blitFS(
            VSOut in [[stage_in]],
            texture2d<float> tex [[texture(0)]],
            constant BlitParams& p [[buffer(0)]],
            sampler s [[sampler(0)]]
        ) {
            float2 inUV = clamp(in.uv, 0.0, 1.0);
            float2 uv = (p.uv * float3(inUV, 1.0)).xy;
            uv = clamp(uv, 0.0, 1.0);
            return tex.sample(s, uv);
        }

        struct YUVParams {
            float3 rCoeffs;
            float3 gCoeffs;
            float3 bCoeffs;
            float3 offsets;
            float3x3 uv;
        };

        fragment float4 blitYUVFS(
            VSOut in [[stage_in]],
            texture2d<float> yTex [[texture(0)]],
            texture2d<float> cbcrTex [[texture(1)]],
            constant YUVParams& p [[buffer(0)]],
            sampler s [[sampler(0)]]
        ) {
            float2 inUV = clamp(in.uv, 0.0, 1.0);
            float2 uv = (p.uv * float3(inUV, 1.0)).xy;
            uv = clamp(uv, 0.0, 1.0);
            float y = yTex.sample(s, uv).r;
            float2 cbcr = cbcrTex.sample(s, uv).rg;
            float3 yuv = float3(y, cbcr.x, cbcr.y) + p.offsets;
            float r = dot(p.rCoeffs, yuv);
            float g = dot(p.gCoeffs, yuv);
            float b = dot(p.bCoeffs, yuv);
            return float4(r, g, b, 1.0);
        }
        """

        do {
            let library = try device.makeLibrary(source: src, options: nil)
            guard let vs = library.makeFunction(name: "blitVS"),
                  let bgraFS = library.makeFunction(name: "blitFS"),
                  let yuvFS = library.makeFunction(name: "blitYUVFS")
            else { return nil }

            let bgraDesc = MTLRenderPipelineDescriptor()
            bgraDesc.vertexFunction = vs
            bgraDesc.fragmentFunction = bgraFS
            bgraDesc.colorAttachments[0].pixelFormat = colorPixelFormat

            let yuvDesc = MTLRenderPipelineDescriptor()
            yuvDesc.vertexFunction = vs
            yuvDesc.fragmentFunction = yuvFS
            yuvDesc.colorAttachments[0].pixelFormat = colorPixelFormat

            let bgra = try device.makeRenderPipelineState(descriptor: bgraDesc)
            let yuv = try device.makeRenderPipelineState(descriptor: yuvDesc)
            return BlitPipelines(bgra: bgra, yuv: yuv)
        } catch {
            NSLog("[MetalPreview] Failed to build blit pipeline: %@", String(describing: error))
            return nil
        }
    }

    private struct YUVParams {
        var rCoeffs: SIMD3<Float>
        var gCoeffs: SIMD3<Float>
        var bCoeffs: SIMD3<Float>
        var offsets: SIMD3<Float>
        var uv: simd_float3x3
    }

    private struct BlitParams {
        var uv: simd_float3x3
    }

    private static func yuvParams(for pb: CVPixelBuffer) -> YUVParams {
        // Pick a reasonable matrix; prefer attachment if present.
        let matrix: String? = {
            let key = kCVImageBufferYCbCrMatrixKey as CFString
            let value = CVBufferCopyAttachment(pb, key, nil)
            return value as? String
        }()

        let is709: Bool = {
            if let matrix {
                return matrix.contains("709")
            }
            // Default to 709 for HD-ish content.
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            return max(w, h) >= 720
        }()

        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let videoRange = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        if videoRange {
            // Video range (limited): Y in [16/255, 235/255], CbCr in [16/255, 240/255]
            // Convert to full-range-ish YUV for matrix multiply.
            let yScale: Float = 255.0 / 219.0
            let cScale: Float = 255.0 / 224.0
            let yOffset: Float = -(16.0 / 255.0) * yScale
            let cOffset: Float = -0.5 * cScale

            if is709 {
                // BT.709
                return YUVParams(
                    rCoeffs: SIMD3(yScale, 0, 1.5748 * cScale),
                    gCoeffs: SIMD3(yScale, -0.1873 * cScale, -0.4681 * cScale),
                    bCoeffs: SIMD3(yScale, 1.8556 * cScale, 0),
                    offsets: SIMD3(yOffset, cOffset, cOffset),
                    uv: matrix_identity_float3x3
                )
            } else {
                // BT.601
                return YUVParams(
                    rCoeffs: SIMD3(yScale, 0, 1.4020 * cScale),
                    gCoeffs: SIMD3(yScale, -0.344136 * cScale, -0.714136 * cScale),
                    bCoeffs: SIMD3(yScale, 1.7720 * cScale, 0),
                    offsets: SIMD3(yOffset, cOffset, cOffset),
                    uv: matrix_identity_float3x3
                )
            }
        } else {
            // Full range: Y in [0,1], CbCr centered at 0.5.
            if is709 {
                return YUVParams(
                    rCoeffs: SIMD3(1, 0, 1.5748),
                    gCoeffs: SIMD3(1, -0.1873, -0.4681),
                    bCoeffs: SIMD3(1, 1.8556, 0),
                    offsets: SIMD3(0, -0.5, -0.5),
                    uv: matrix_identity_float3x3
                )
            } else {
                return YUVParams(
                    rCoeffs: SIMD3(1, 0, 1.4020),
                    gCoeffs: SIMD3(1, -0.344136, -0.714136),
                    bCoeffs: SIMD3(1, 1.7720, 0),
                    offsets: SIMD3(0, -0.5, -0.5),
                    uv: matrix_identity_float3x3
                )
            }
        }
    }

    private enum FrameOrientation: Sendable {
        case up
        case down
        case left
        case right
        case upMirrored
        case downMirrored
        case leftMirrored
        case rightMirrored
    }

    private static func approx(_ x: CGFloat, _ y: CGFloat, tol: CGFloat = 0.01) -> Bool {
        abs(x - y) <= tol
    }

    private static func orientation(from t: CGAffineTransform) -> FrameOrientation {
        // We intentionally ignore translation (tx/ty). For video tracks, translation is often
        // used to keep the rotated image in positive coordinates; using it directly for UVs
        // causes visible shifting. Rotation+mirror is enough for correct sampling.
        let a = t.a
        let b = t.b
        let c = t.c
        let d = t.d

        // Common cases (rounded):
        // up:           [ 1  0 ;  0  1 ]
        // down:         [-1  0 ;  0 -1 ]
        // left (CCW):   [ 0  1 ; -1  0 ]
        // right (CW):   [ 0 -1 ;  1  0 ]
        // upMirrored:   [-1  0 ;  0  1 ]
        // downMirrored: [ 1  0 ;  0 -1 ]
        // leftMirrored: [ 0  1 ;  1  0 ]
        // rightMirrored:[ 0 -1 ; -1  0 ]

        if approx(a, 1), approx(b, 0), approx(c, 0), approx(d, 1) { return .up }
        if approx(a, -1), approx(b, 0), approx(c, 0), approx(d, -1) { return .down }
        if approx(a, 0), approx(b, 1), approx(c, -1), approx(d, 0) { return .left }
        if approx(a, 0), approx(b, -1), approx(c, 1), approx(d, 0) { return .right }
        if approx(a, -1), approx(b, 0), approx(c, 0), approx(d, 1) { return .upMirrored }
        if approx(a, 1), approx(b, 0), approx(c, 0), approx(d, -1) { return .downMirrored }
        if approx(a, 0), approx(b, 1), approx(c, 1), approx(d, 0) { return .leftMirrored }
        if approx(a, 0), approx(b, -1), approx(c, -1), approx(d, 0) { return .rightMirrored }

        return .up
    }

    private static func displaySize(sourceSize: CGSize, orientation: FrameOrientation) -> CGSize {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: sourceSize.height, height: sourceSize.width)
        default:
            return sourceSize
        }
    }

    private static func uvMatrix(for orientation: FrameOrientation) -> simd_float3x3 {
        // Maps inUV (display space) -> uv (source texture space).
        // Conventions:
        // - UV origin is top-left (as used by our full-screen triangle).
        // - The mappings match common EXIF-like orientations.
        switch orientation {
        case .up:
            return simd_float3x3(columns: (
                SIMD3(1, 0, 0),
                SIMD3(0, 1, 0),
                SIMD3(0, 0, 1)
            ))
        case .down:
            // (u,v) -> (1-u, 1-v)
            return simd_float3x3(columns: (
                SIMD3(-1, 0, 0),
                SIMD3(0, -1, 0),
                SIMD3(1, 1, 1)
            ))
        case .left:
            // 90° CCW: (u,v) -> (1-v, u)
            return simd_float3x3(columns: (
                SIMD3(0, 1, 0),
                SIMD3(-1, 0, 0),
                SIMD3(1, 0, 1)
            ))
        case .right:
            // 90° CW: (u,v) -> (v, 1-u)
            return simd_float3x3(columns: (
                SIMD3(0, -1, 0),
                SIMD3(1, 0, 0),
                SIMD3(0, 1, 1)
            ))
        case .upMirrored:
            // mirror X: (u,v) -> (1-u, v)
            return simd_float3x3(columns: (
                SIMD3(-1, 0, 0),
                SIMD3(0, 1, 0),
                SIMD3(1, 0, 1)
            ))
        case .downMirrored:
            // mirror Y: (u,v) -> (u, 1-v)
            return simd_float3x3(columns: (
                SIMD3(1, 0, 0),
                SIMD3(0, -1, 0),
                SIMD3(0, 1, 1)
            ))
        case .leftMirrored:
            // transpose: (u,v) -> (v, u)
            return simd_float3x3(columns: (
                SIMD3(0, 1, 0),
                SIMD3(1, 0, 0),
                SIMD3(0, 0, 1)
            ))
        case .rightMirrored:
            // anti-transpose: (u,v) -> (1-v, 1-u)
            return simd_float3x3(columns: (
                SIMD3(0, -1, 0),
                SIMD3(-1, 0, 0),
                SIMD3(1, 1, 1)
            ))
        }
    }

    func setFrame(
        pixelBuffer pb: CVPixelBuffer?,
        preferredTransform t: CGAffineTransform,
        canvasBackgroundBGRA bgra: SIMD4<UInt8>,
        canvasSize: CGSize
    ) {
        lock.lock()
        pixelBuffer = pb
        preferredTransform = t
        if canvasBackgroundBGRA != bgra {
            canvasBackgroundBGRA = bgra
            canvasBackgroundTexture = Self.makeSolidBGRA8Texture(device: device, b: bgra.x, g: bgra.y, r: bgra.z, a: bgra.w)
        }
        self.canvasSize = canvasSize
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // no-op
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        lock.lock()
        let pb = pixelBuffer
        let trackPreferredTransform = preferredTransform
        let canvas = canvasSize
        lock.unlock()

        // Viewer background (outside the project canvas) should follow app/window background,
        // not a hard-coded black.
        let passClear = MTLRenderPassDescriptor()
        passClear.colorAttachments[0].texture = drawable.texture
        passClear.colorAttachments[0].loadAction = .clear
        passClear.colorAttachments[0].storeAction = .store
        passClear.colorAttachments[0].clearColor = Self.windowBackgroundClearColor()

        let passLoad = MTLRenderPassDescriptor()
        passLoad.colorAttachments[0].texture = drawable.texture
        passLoad.colorAttachments[0].loadAction = .load
        passLoad.colorAttachments[0].storeAction = .store

        let dstRect = CGRect(
            x: 0,
            y: 0,
            width: Double(drawable.texture.width),
            height: Double(drawable.texture.height)
        )

                    if let pb,
              let cache = textureCache,
              let bgraPipeline = blitBGRAPipeline,
              let yuvPipeline = blitYUVPipeline,
              let sampler = blitSampler {
            let fmt = CVPixelBufferGetPixelFormatType(pb)

                        // If the pixelBuffer already matches the project canvas size, it's very likely
                        // post-videoComposition (i.e. transforms/conform already baked in). In that case,
                        // applying track preferredTransform again for UV rotation will produce shifted/corner output.
                        let t: CGAffineTransform = Self.shouldIgnorePreferredTransform(pb: pb, canvasSize: canvas)
                                ? .identity
                                : trackPreferredTransform

            let srcSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
            let orientation = Self.orientation(from: t)
            let displaySize = Self.displaySize(sourceSize: srcSize, orientation: orientation)
            let uv = Self.uvMatrix(for: orientation)

            let canvasSize: CGSize = {
                if canvas.width > 1, canvas.height > 1 {
                    return canvas
                }
                return displaySize
            }()

            let canvasRect = Self.aspectFitRect(contentSize: canvasSize, in: dstRect)
            let sourceRect = Self.aspectFitRect(contentSize: displaySize, in: canvasRect)

            if Self.isGeometryDebugEnabled {
                NSLog(
                    "[MetalPreview] pb=%.0fx%.0f canvas=%.0fx%.0f ignoreTransform=%@ orientation=%@ dst=%.0fx%.0f canvasRect=(%.1f,%.1f,%.1f,%.1f) sourceRect=(%.1f,%.1f,%.1f,%.1f)",
                    srcSize.width,
                    srcSize.height,
                    canvasSize.width,
                    canvasSize.height,
                    Self.shouldIgnorePreferredTransform(pb: pb, canvasSize: canvas) ? "yes" : "no",
                    String(describing: orientation),
                    dstRect.width,
                    dstRect.height,
                    canvasRect.minX,
                    canvasRect.minY,
                    canvasRect.width,
                    canvasRect.height,
                    sourceRect.minX,
                    sourceRect.minY,
                    sourceRect.width,
                    sourceRect.height
                )
            }

            // Fill project canvas region every frame (canvas background).
            if let canvasBackgroundTexture {
                let canvasViewport = MTLViewport(
                    originX: Double(canvasRect.minX),
                    originY: Double(canvasRect.minY),
                    width: Double(max(1, canvasRect.width)),
                    height: Double(max(1, canvasRect.height)),
                    znear: 0,
                    zfar: 1
                )
                var params = BlitParams(uv: matrix_identity_float3x3)
                Self.drawTextured(
                    encoderDescriptor: passClear,
                    commandBuffer: commandBuffer,
                    pipeline: bgraPipeline,
                    sampler: sampler,
                    viewport: canvasViewport,
                    configure: { encoder in
                        encoder.setFragmentTexture(canvasBackgroundTexture, index: 0)
                        encoder.setFragmentBytes(&params, length: MemoryLayout<BlitParams>.stride, index: 0)
                    }
                )
            } else {
                // At least clear the viewer background.
                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passClear) {
                    encoder.endEncoding()
                }
            }

            let viewport = MTLViewport(
                originX: Double(sourceRect.minX),
                originY: Double(sourceRect.minY),
                width: Double(max(1, sourceRect.width)),
                height: Double(max(1, sourceRect.height)),
                znear: 0,
                zfar: 1
            )

            if fmt == kCVPixelFormatType_32BGRA {
                let srcW = CVPixelBufferGetWidth(pb)
                let srcH = CVPixelBufferGetHeight(pb)
                var cvTex: CVMetalTexture?
                let status = CVMetalTextureCacheCreateTextureFromImage(
                    nil,
                    cache,
                    pb,
                    nil,
                    .bgra8Unorm,
                    srcW,
                    srcH,
                    0,
                    &cvTex
                )
                if status == kCVReturnSuccess, let cvTex, let srcTex = CVMetalTextureGetTexture(cvTex) {
                    var params = BlitParams(uv: uv)
                    Self.drawTextured(
                        encoderDescriptor: passLoad,
                        commandBuffer: commandBuffer,
                        pipeline: bgraPipeline,
                        sampler: sampler,
                        viewport: viewport,
                        configure: { encoder in
                            encoder.setFragmentTexture(srcTex, index: 0)
                            encoder.setFragmentBytes(&params, length: MemoryLayout<BlitParams>.stride, index: 0)
                        }
                    )
                } else {
                    Self.renderWithCI(
                        pb: pb,
                        drawableTexture: drawable.texture,
                        commandBuffer: commandBuffer,
                        ciContext: ciContext,
                        targetRect: sourceRect
                    )
                }
            } else if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                      CVPixelBufferGetPlaneCount(pb) >= 2
            {
                let yW = CVPixelBufferGetWidthOfPlane(pb, 0)
                let yH = CVPixelBufferGetHeightOfPlane(pb, 0)
                let cW = CVPixelBufferGetWidthOfPlane(pb, 1)
                let cH = CVPixelBufferGetHeightOfPlane(pb, 1)

                var yTexRef: CVMetalTexture?
                var cTexRef: CVMetalTexture?
                let yStatus = CVMetalTextureCacheCreateTextureFromImage(
                    nil,
                    cache,
                    pb,
                    nil,
                    .r8Unorm,
                    yW,
                    yH,
                    0,
                    &yTexRef
                )
                let cStatus = CVMetalTextureCacheCreateTextureFromImage(
                    nil,
                    cache,
                    pb,
                    nil,
                    .rg8Unorm,
                    cW,
                    cH,
                    1,
                    &cTexRef
                )

                if yStatus == kCVReturnSuccess,
                   cStatus == kCVReturnSuccess,
                   let yTexRef,
                   let cTexRef,
                   let yTex = CVMetalTextureGetTexture(yTexRef),
                   let cTex = CVMetalTextureGetTexture(cTexRef)
                {
                    var params = Self.yuvParams(for: pb)
                    params.uv = uv
                    Self.drawTextured(
                        encoderDescriptor: passLoad,
                        commandBuffer: commandBuffer,
                        pipeline: yuvPipeline,
                        sampler: sampler,
                        viewport: viewport,
                        configure: { encoder in
                            encoder.setFragmentTexture(yTex, index: 0)
                            encoder.setFragmentTexture(cTex, index: 1)
                            encoder.setFragmentBytes(&params, length: MemoryLayout<YUVParams>.stride, index: 0)
                        }
                    )
                } else {
                    Self.renderWithCI(
                        pb: pb,
                        drawableTexture: drawable.texture,
                        commandBuffer: commandBuffer,
                        ciContext: ciContext,
                        targetRect: sourceRect
                    )
                }
            } else {
                Self.renderWithCI(
                    pb: pb,
                    drawableTexture: drawable.texture,
                    commandBuffer: commandBuffer,
                    ciContext: ciContext,
                    targetRect: sourceRect
                )
            }
        } else if let pb {
            // Clear viewer background even when we can't use the Metal blit path.
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passClear) {
                encoder.endEncoding()
            }
            Self.renderWithCI(pb: pb, drawableTexture: drawable.texture, commandBuffer: commandBuffer, ciContext: ciContext, targetRect: nil)
        } else {
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passClear) {
                encoder.endEncoding()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func renderWithCI(
        pb: CVPixelBuffer,
        drawableTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        ciContext: CIContext,
        targetRect: CGRect?
    ) {
        let image = CIImage(cvPixelBuffer: pb)
        let destRect = CGRect(origin: .zero, size: CGSize(width: drawableTexture.width, height: drawableTexture.height))

        let target: CGRect = {
            if let targetRect {
                return targetRect
            }
            // Aspect-fit into drawable.
            let srcExtent = image.extent
            let scale = min(destRect.width / srcExtent.width, destRect.height / srcExtent.height)
            let scaledW = srcExtent.width * scale
            let scaledH = srcExtent.height * scale
            let x = (destRect.width - scaledW) / 2
            let y = (destRect.height - scaledH) / 2
            return CGRect(x: x, y: y, width: scaledW, height: scaledH)
        }()

        ciContext.render(
            image,
            to: drawableTexture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
    }

    private static func drawTextured(
        encoderDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        sampler: MTLSamplerState,
        viewport: MTLViewport,
        configure: (MTLRenderCommandEncoder) -> Void
    ) {
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: encoderDescriptor) {
            encoder.setViewport(viewport)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentSamplerState(sampler, index: 0)
            configure(encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    private static func aspectFitRect(contentSize: CGSize, in containerRect: CGRect) -> CGRect {
        let cw = Double(contentSize.width)
        let ch = Double(contentSize.height)
        let rw = Double(containerRect.width)
        let rh = Double(containerRect.height)
        guard cw > 0.01, ch > 0.01, rw > 0.01, rh > 0.01 else { return containerRect }

        let scale = min(rw / cw, rh / ch)
        let w = max(1.0, cw * scale)
        let h = max(1.0, ch * scale)
        let x = Double(containerRect.minX) + (rw - w) / 2.0
        let y = Double(containerRect.minY) + (rh - h) / 2.0
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func shouldIgnorePreferredTransform(pb: CVPixelBuffer, canvasSize: CGSize) -> Bool {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return false }
        let w = CGFloat(CVPixelBufferGetWidth(pb))
        let h = CGFloat(CVPixelBufferGetHeight(pb))
        // Tolerate 1px rounding differences.
        let same = abs(w - canvasSize.width) <= 1 && abs(h - canvasSize.height) <= 1
        return same
    }
}

struct MetalPreviewViewRepresentable: NSViewRepresentable {
    let pixelBuffer: CVPixelBuffer?
    let quality: PreviewQuality
    let preferredTransform: CGAffineTransform
    let canvasBackgroundColor: NSColor
    let canvasSize: CGSize

    private static let isGeometryDebugEnabled: Bool = {
        ProcessInfo.processInfo.environment["YUNQI_METALPREVIEW_DEBUG"] == "1"
    }()

    private static let realtimeScale: Double = {
        // Conservative default: render at 1/2 resolution while playing.
        // Can be tuned later or made configurable via settings.
        0.5
    }()

    final class Coordinator {
        var renderer: MetalPreviewRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class ResizingMTKView: MTKView {
        var drawableSizeScale: CGFloat = 1.0

        override func layout() {
            super.layout()
            let boundsSize = bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return }

            let backingScale = window?.backingScaleFactor
                ?? window?.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0

            let target = CGSize(
                width: max(1, boundsSize.width * backingScale * drawableSizeScale),
                height: max(1, boundsSize.height * backingScale * drawableSizeScale)
            )

            if drawableSize != target {
                drawableSize = target
            }

            // We're in enableSetNeedsDisplay mode.
            setNeedsDisplay(bounds)
        }
    }

    @MainActor
    func makeNSView(context: Context) -> MTKView {
        let v = ResizingMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        // We control drawableSize explicitly to support quality tiers.
        v.autoResizeDrawable = false

        context.coordinator.renderer = MetalPreviewRenderer(mtkView: v)
        return v
    }

    @MainActor
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.setFrame(
            pixelBuffer: pixelBuffer,
            preferredTransform: preferredTransform,
            canvasBackgroundBGRA: Self.bgraBytes(from: canvasBackgroundColor),
            canvasSize: canvasSize
        )

        // Keep drawableSize stable per quality tier, but update it reliably during resize/fullscreen
        // via our MTKView.layout() override.
        let qualityScale: CGFloat = 1.0
        if let v = nsView as? ResizingMTKView {
            v.drawableSizeScale = qualityScale
            v.needsLayout = true
        }

        if Self.isGeometryDebugEnabled {
            let b = nsView.bounds.size
            NSLog(
                "[MetalPreview] bounds=%.1fx%.1f drawable=%.0fx%.0f windowScale=%.2f",
                b.width,
                b.height,
                nsView.drawableSize.width,
                nsView.drawableSize.height,
                nsView.window?.backingScaleFactor ?? 0
            )
        }

        nsView.setNeedsDisplay(nsView.bounds)
    }

    private static func bgraBytes(from color: NSColor) -> SIMD4<UInt8> {
        let srgb = (color.usingColorSpace(.sRGB) ?? color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

        func clampByte(_ x: CGFloat) -> UInt8 {
            let v = max(0, min(255, Int((x * 255.0).rounded())))
            return UInt8(v)
        }

        return SIMD4<UInt8>(clampByte(b), clampByte(g), clampByte(r), clampByte(a))
    }
}
