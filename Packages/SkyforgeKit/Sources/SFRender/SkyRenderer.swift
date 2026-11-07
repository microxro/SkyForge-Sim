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
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RendererError.pipeline(String(describing: error))
        }
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
        var u = SkyUniforms(
            sunDirection: SIMD3<Float>(0.35, 0.12, -1.0),
            time: Float(CACurrentMediaTime() - startTime),
            zenithColor: SIMD3<Float>(0.16, 0.32, 0.62),
            exposure: 1.1,
            horizonColor: SIMD3<Float>(0.95, 0.70, 0.48),
            aspect: aspect
        )
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
#endif
