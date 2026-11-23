// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Foundation
import SFAtmosphere

extension WorldRenderer {
    /// The one setup for a real airport. The app (`QuickFlightView`) and the frames harness (`ShowcaseRenderTests`)
    /// both call this, so the scene they render cannot drift apart. The caller chooses only what is genuinely
    /// per-run: `clouds` (live weather in the app, a fixed layer in tests); nil means fair-weather cumulus.
    public func applyRealAirport(_ data: RealWorldRenderData, fieldElevation: Double, clouds: CloudLayer? = nil) throws {
        try setRealWorld(data)
        self.clouds = clouds ?? .fairWeather(fieldElevation: Float(fieldElevation))
    }
}
#endif
