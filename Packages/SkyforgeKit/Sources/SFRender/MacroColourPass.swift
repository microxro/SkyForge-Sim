// SKYFORGE — Apache-2.0
// Round 3 host side: builds the 64 m macro-colour texture (`macro_colour_build` in MacroColourShaders) from the
// near imagery layer. The world shader samples it at texture index 10 when `WorldRenderer.macroColourDecoupling`
// is on; with it off (the default) the texture is built but never read.
import Metal
import simd

/// Mirror of the MSL `MCBuildParams` (32 bytes: float2 at 0, three floats at 8/12/16, uint at 20, uint2 at 24).
struct MacroColourBuildParams {
    var centre: SIMD2<Float>
    var halfExtent: Float
    var cellMetres: Float
    var texelMetres: Float
    var size: UInt32
    var pad: SIMD2<UInt32> = .zero
}

enum MacroColourPass {
    /// Target texel size (m). The actual size is `2 · half / size` with `size = ceil(2 · half / 64)`, so the grid
    /// always spans the imagery square exactly (a fixed 64 m cell stretched the lookup by up to 2.4 %).
    static let targetCell = 64.0

    /// A 1×1 texture whose alpha is 0: the shader skips the pass where the macro texel is missing. (The shared
    /// `dummy2D` has alpha 1, so it cannot stand in.)
    static func zeroTexture(device: MTLDevice) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        let t = device.makeTexture(descriptor: d)!
        var px = [UInt16](repeating: 0, count: 4)
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 8)
        return t
    }

    /// Runs the kernel once for a near imagery layer (`image` must be mipmapped). Returns an rgba16Float texture,
    /// row 0 north like the imagery: rgb = 128 m mean photo colour, a = 128 m median luminance.
    static func build(image: MTLTexture, centre: SIMD2<Double>, half: Double, library: MTLLibrary,
                      device: MTLDevice, queue: MTLCommandQueue) throws -> MTLTexture {
        guard let fn = library.makeFunction(name: "macro_colour_build") else {
            throw RendererError.shaderCompile("missing macro_colour_build")
        }
        let pipeline: MTLComputePipelineState
        do { pipeline = try device.makeComputePipelineState(function: fn) }
        catch { throw RendererError.pipeline(String(describing: error)) }
        let size = max(4, Int((2 * half / targetCell).rounded(.up)))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size, height: size, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let out = device.makeTexture(descriptor: d), let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { throw RendererError.commandQueue }
        var p = MacroColourBuildParams(centre: SIMD2(Float(centre.x), Float(centre.y)), halfExtent: Float(half),
                                       cellMetres: Float(2 * half / Double(size)), texelMetres: Float(2 * half / Double(image.width)),
                                       size: UInt32(size))
        enc.setComputePipelineState(pipeline)
        enc.setTexture(image, index: 0)
        enc.setTexture(out, index: 1)
        enc.setBytes(&p, length: MemoryLayout<MacroColourBuildParams>.stride, index: 0)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        enc.dispatchThreads(MTLSize(width: size, height: size, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return out
    }
}
