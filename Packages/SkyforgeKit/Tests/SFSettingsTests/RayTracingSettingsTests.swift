// SKYFORGE — Apache-2.0
import Foundation
import Testing
@testable import SFSettings

@Suite("Ray tracing intensity and features")
struct RayTracingSettingsTests {
    @Test func intensityIsEnabledOnlyWhenNotOff() {
        #expect(!RayTracingMode.off.isEnabled)
        #expect(RayTracingMode.rayTraced.isEnabled)
        #expect(RayTracingMode.pathTraced.isEnabled)
    }

    @Test func featureDefaultsAreAllOn() {
        let f = RayTracingFeatures()
        #expect(f.shadows && f.reflections && f.ambientOcclusion && f.globalIllumination)
    }

    @Test func legacyRayTracingValuesDecodeAsRayTraced() throws {
        for legacy in ["reflections", "full"] {
            let data = Data("\"\(legacy)\"".utf8)
            #expect(try JSONDecoder().decode(RayTracingMode.self, from: data) == .rayTraced)
        }
    }

    @Test func unknownRayTracingValueFallsBackToOff() throws {
        let data = Data("\"something-new\"".utf8)
        #expect(try JSONDecoder().decode(RayTracingMode.self, from: data) == .off)
    }

    @Test func graphicsSettingsWithoutFeatureKeysStillDecode() throws {
        // Encode today's settings, then drop the two RT keys, as an older build would have written them.
        let encoded = try JSONEncoder().encode(GraphicsSettings())
        var obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        obj.removeValue(forKey: "rayTracing")
        obj.removeValue(forKey: "rayTracingFeatures")
        let old = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(GraphicsSettings.self, from: old)
        #expect(decoded.rayTracing == .off)
        #expect(decoded.rayTracingFeatures == RayTracingFeatures())
    }

    @Test func graphicsSettingsRoundTripKeepsRayTracing() throws {
        var g = GraphicsSettings()
        g.rayTracing = .pathTraced
        g.rayTracingFeatures.reflections = false
        let data = try JSONEncoder().encode(g)
        let back = try JSONDecoder().decode(GraphicsSettings.self, from: data)
        #expect(back == g)
    }
}
