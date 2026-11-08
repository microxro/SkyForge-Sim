// SKYFORGE — Apache-2.0
#if canImport(Metal) && canImport(MetalKit)
import Foundation
import Metal
import MetalKit

/// Matches `SkyUniforms` in SkyShaders.source (float3 is 16-byte aligned in MSL constant buffers).
struct SkyUniforms {
    var sunDirection: SIMD3<Float>
    var time: Float
    var zenithColor: SIMD3<Float>
    var exposure: Float
    var horizonColor: SIMD3<Float>
    var aspect: Float
}

public enum RendererError: Error {
    case noDevice
    case commandQueue
    case shaderCompile(String)
    case pipeline(String)
}

extension SkyUniforms {
    init(_ p: SkyParams, aspect: Float) {
        self.init(sunDirection: p.sunDirection, time: p.time, zenithColor: p.zenithColor, exposure: p.exposure,
                  horizonColor: p.horizonColor, aspect: aspect)
    }
}

/// Compiles the sky pipeline for a colour/depth format (shared by on-screen and offscreen paths).
enum SkyPipeline {
    static func make(device: MTLDevice, color: MTLPixelFormat, depth: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: SkyShaders.source, options: nil)
        } catch {
            throw RendererError.shaderCompile(String(describing: error))
        }
        guard let vfn = library.makeFunction(name: "sky_vertex"),
              let ffn = library.makeFunction(name: "sky_fragment") else {
            throw RendererError.shaderCompile("missing sky functions")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Sky"
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = color
        desc.depthAttachmentPixelFormat = depth
        do {
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RendererError.pipeline(String(describing: error))
        }
    }
}

/// P0 renderer: draws the procedural sky with a runtime-compiled pipeline.
/// Terrain, aircraft and SkyWorld passes are added in P1.
@MainActor
public final class SkyRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var startTime = CACurrentMediaTime()

    public init(view: MTKView) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.commandQueue }
        self.device = device
        self.queue = queue
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 0.0

        pipeline = try SkyPipeline.make(device: device, color: view.colorPixelFormat, depth: view.depthStencilPixelFormat)
        super.init()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        let aspect = size.height > 0 ? Float(size.width / size.height) : 1
        var params = SkyParams()
        params.time = Float(CACurrentMediaTime() - startTime)
        var u = SkyUniforms(params, aspect: aspect)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

/// Renders into an offscreen texture and reads it back (visual regression, §8.7). Runs wherever
/// `MTLCreateSystemDefaultDevice()` returns a device; callers skip cleanly otherwise.
public final class OffscreenSkyRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.commandQueue }
        self.device = device
        self.queue = queue
        pipeline = try SkyPipeline.make(device: device, color: .rgba8Unorm, depth: .invalid)
    }

    /// RGB8 pixels, rows top to bottom.
    public func render(width: Int, height: Int, params: SkyParams = SkyParams()) throws -> [UInt8] {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let target = device.makeTexture(descriptor: td),
              let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer() else { throw RendererError.commandQueue }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { throw RendererError.commandQueue }
        var u = SkyUniforms(params, aspect: Float(width) / Float(height))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        guard let blit = cmd.makeBlitCommandEncoder() else { throw RendererError.commandQueue }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let err = cmd.error { throw RendererError.pipeline(String(describing: err)) }
        let src = readback.contents().bindMemory(to: UInt8.self, capacity: width * height * 4)
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for p in 0..<(width * height) {
            out[3 * p] = src[4 * p]; out[3 * p + 1] = src[4 * p + 1]; out[3 * p + 2] = src[4 * p + 2]
        }
        return out
    }
}
#endif
