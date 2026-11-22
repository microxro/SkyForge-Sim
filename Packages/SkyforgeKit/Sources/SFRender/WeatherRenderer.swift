// SKYFORGE — Apache-2.0
// Precipitation, wet-air veil and lightning overlay (see WeatherShaders). Encoded after the cloud
// composite; costs one full-screen triangle, so it is cheap on every device tier.
#if canImport(Metal)
import Foundation
import Metal
import simd
import SFWeather

/// Matches `WeatherUniforms` in WeatherShaders.source (four float4).
struct WeatherUniforms {
    var look: SIMD4<Float> = .zero
    var params: SIMD4<Float> = .zero
    var motion: SIMD4<Float> = SIMD4(0, 1, 0, 0)
    var tint: SIMD4<Float> = SIMD4(0.75, 0.80, 0.88, 0)

    init() {}

    /// - Parameters:
    ///   - time: simulation or wall-clock seconds (only differences matter).
    ///   - aspect: framebuffer width / height.
    ///   - airspeed: true airspeed (m/s); rain streaks slant and speed up as the aircraft flies through them.
    ///   - lightning: flash brightness 0…1 (`WeatherEffects.lightning(at:)`).
    ///   - ambient: linear RGB of the sky/ground ambient light; tints the drops (dim at dusk).
    init(effects e: WeatherEffects, time: Double, aspect: Double, airspeed: Double, lightning: Double, ambient: SIMD3<Float>) {
        let look = e.precipitationLook
        let kind: Float
        switch e.precipitation {
        case .none: kind = 0
        case .drizzle: kind = 1
        case .rain: kind = 2
        case .snow: kind = 3
        case .hail: kind = 4
        }
        self.look = SIMD4(look.density, look.fallSpeed, look.streakLength, look.wetness)
        // Slant: drops fall at `fallSpeed` while the aircraft moves forward at `airspeed`; the apparent
        // angle from vertical is atan(v/fall). Clamp so streaks stay within ~60° of vertical.
        let slant = look.fallSpeed > 0 ? Float(min(airspeed / Double(look.fallSpeed), 1.7)) : 0
        params = SIMD4(kind, Float(time.truncatingRemainder(dividingBy: 3_600)), Float(lightning), Float(aspect))
        motion = SIMD4(slant * 0.35, Float(1 + min(airspeed / 60, 1.5)), 0, 0)
        tint = SIMD4(ambient.x, ambient.y, ambient.z, 0)
    }
}

public final class WeatherRenderer {
    public let device: MTLDevice
    private let pipeline: MTLRenderPipelineState

    public init(device: MTLDevice, colorFormat: MTLPixelFormat) throws {
        self.device = device
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: WeatherShaders.source, options: nil) }
        catch { throw RendererError.shaderCompile(String(describing: error)) }
        guard let v = lib.makeFunction(name: "weather_vertex"), let f = lib.makeFunction(name: "weather_fragment") else {
            throw RendererError.shaderCompile("missing weather functions")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "WeatherOverlay"
        d.vertexFunction = v; d.fragmentFunction = f
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = colorFormat
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do { pipeline = try device.makeRenderPipelineState(descriptor: d) }
        catch { throw RendererError.pipeline(String(describing: error)) }
    }

    /// True when the effects need an overlay at all (skip the pass otherwise).
    public static func needsOverlay(_ e: WeatherEffects, lightning: Double) -> Bool {
        e.precipitation != .none || lightning > 0.001
    }

    /// Blends the overlay over `colour`.
    public func encode(cmd: MTLCommandBuffer, colour: MTLTexture, effects: WeatherEffects, time: Double, airspeed: Double,
                       lightning: Double, ambient: SIMD3<Float>) throws {
        var u = WeatherUniforms(effects: effects, time: time, aspect: Double(colour.width) / Double(max(1, colour.height)),
                                airspeed: airspeed, lightning: lightning, ambient: ambient)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { throw RendererError.commandQueue }
        enc.label = "Weather overlay"
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<WeatherUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
#endif
