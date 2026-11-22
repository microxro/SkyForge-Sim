// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Testing
import Foundation
import Metal
import simd
@testable import SFRender
import SFQuickFlight
import SFPreview
import SFWeather

/// Weather hookups in the world renderer: clear weather changes nothing, fog flattens the distance toward the
/// horizon colour, and rain adds the precipitation overlay.
@Suite struct WeatherRenderTests {
    private func frame(_ effects: WeatherEffects?) throws -> (img: [UInt8], w: Int, h: Int) {
        let world = QuickFlightWorld()
        var d = QuickFlightDetail.phone
        d.objectRadius = 400; d.nearHalfExtent = 800; d.midHalfExtent = 2_000; d.farHalfExtent = 5_000
        let lighting = LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: 40)
        let r = try WorldRenderer(lighting: lighting)
        try r.setEnvironment(world.buildEnvironment(detail: d))
        if let effects { r.weatherEffects = effects }
        r.weatherAirspeed = 40
        let eye = SIMD3<Double>(world.runwayCentre.x, world.runwayCentre.y, world.runwayElevation + 40)
        let cam = WorldCamera(position: eye, target: eye + SIMD3<Double>(0, 1, -0.02) * 2_000)
        let w = 320, h = 180
        return (try r.render(width: w, height: h, camera: cam), w, h)
    }

    private func luminanceSpread(_ f: (img: [UInt8], w: Int, h: Int)) -> Double {
        var sum = 0.0, sum2 = 0.0, n = 0.0
        for i in 0..<(f.w * f.h) {
            let l = 0.2126 * Double(f.img[3 * i]) + 0.7152 * Double(f.img[3 * i + 1]) + 0.0722 * Double(f.img[3 * i + 2])
            sum += l; sum2 += l * l; n += 1
        }
        let m = sum / n
        return (max(0, sum2 / n - m * m)).squareRoot()
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func clearWeatherLeavesTheFrameUnchanged() throws {
        let base = try frame(nil)
        let clear = try frame(.clear)
        #expect(base.img == clear.img, "default and explicit clear weather render identically")
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func fogFlattensTheDistance() throws {
        let clear = try frame(nil)
        let foggy = WeatherEffects(precipitation: .none, precipitationIntensity: 0, visibilityMetres: 300,
                                   fogExtinction: WeatherEffects.extinction(visibility: 300), groundFog: true, thunderstorm: false,
                                   windSpeed: 0, gust: 0, turbulence: 0)
        let fog = try frame(foggy)
        #expect(fog.img != clear.img, "300 m visibility changes the frame")
        #expect(luminanceSpread(fog) < luminanceSpread(clear), "fog lowers the frame's contrast")
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func rainAddsTheOverlay() throws {
        let clear = try frame(nil)
        let rain = WeatherEffects(precipitation: .rain, precipitationIntensity: 0.9, visibilityMetres: 8_000,
                                  fogExtinction: WeatherEffects.extinction(visibility: 8_000), groundFog: false, thunderstorm: false,
                                  windSpeed: 5, gust: 0, turbulence: 0.2)
        let wet = try frame(rain)
        var changed = 0
        for i in 0..<(clear.w * clear.h) where abs(Int(clear.img[3 * i + 1]) - Int(wet.img[3 * i + 1])) > 4 { changed += 1 }
        #expect(changed > clear.w * clear.h / 50, "rain streaks and the wet veil alter at least 2 % of the pixels")
    }
}
#endif
