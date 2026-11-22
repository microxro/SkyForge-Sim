// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFWeather

@Suite struct WeatherEffectsTests {
    static func fx(_ s: String) throws -> WeatherEffects { WeatherEffects(metar: try METARParser.parse(s)) }

    @Test func clearSkyHasNoPrecipitation() throws {
        let e = try Self.fx("KMRY 221656Z 27008KT 10SM CLR 16/08 A3002")
        #expect(e.precipitation == .none)
        #expect(e.precipitationIntensity == 0)
        #expect(!e.thunderstorm)
        #expect(e.precipitationLook.density == 0)
    }

    @Test func intensityPrefixesOrder() throws {
        let light = try Self.fx("KSEA 221656Z 18010KT 5SM -RA BKN015 10/08 A2990")
        let mod = try Self.fx("KSEA 221656Z 18010KT 3SM RA BKN012 10/08 A2990")
        let heavy = try Self.fx("KSEA 221656Z 18010KT 1SM +RA OVC008 10/08 A2990")
        #expect(light.precipitation == .rain)
        #expect(light.precipitationIntensity < mod.precipitationIntensity)
        #expect(mod.precipitationIntensity < heavy.precipitationIntensity)
    }

    @Test func snowHailDrizzleAndThunder() throws {
        #expect(try Self.fx("KBOS 221656Z 02012KT 1SM SN OVC010 M02/M04 A2995").precipitation == .snow)
        #expect(try Self.fx("KDEN 221656Z 18015G30KT 2SM +TSGR BKN030CB 20/10 A2980").precipitation == .hail)
        #expect(try Self.fx("KLAX 221656Z 25005KT 5SM DZ OVC005 14/13 A2999").precipitation == .drizzle)
        let ts = try Self.fx("KMCO 221656Z 18015G28KT 3SM +TSRA BKN025CB 27/23 A2992")
        #expect(ts.thunderstorm)
        #expect(ts.turbulence > 0.5)
    }

    @Test func vicinityPrecipitationIsIgnored() throws {
        #expect(try Self.fx("KORD 221656Z 27010KT 9SM VCSH SCT040 12/05 A3001").precipitation == .none)
    }

    @Test func fogGivesHighExtinction() throws {
        let fog = try Self.fx("KSFO 221656Z 00000KT 1/4SM FG VV002 12/12 A3002")
        #expect(fog.groundFog)
        #expect(fog.fogExtinction > 3.912 / 600)
        let clear = try Self.fx("KSFO 221656Z 28008KT 10SM CLR 16/08 A3002")
        #expect(clear.fogExtinction < fog.fogExtinction / 10)
    }

    @Test func extinctionIsClampedAndMonotone() {
        #expect(WeatherEffects.extinction(visibility: 0) == 3.912 / 50)
        #expect(WeatherEffects.extinction(visibility: 1e9) == 3.912 / 80_000)
        #expect(WeatherEffects.extinction(visibility: 500) > WeatherEffects.extinction(visibility: 5_000))
    }

    @Test func gustsRaiseTurbulenceAndWindOscillates() throws {
        let calm = try Self.fx("KMRY 221656Z 27004KT 10SM CLR 16/08 A3002")
        let gusty = try Self.fx("KMRY 221656Z 27018G32KT 10SM CLR 16/08 A3002")
        #expect(gusty.turbulence > calm.turbulence)
        let speeds = stride(from: 0.0, to: 60.0, by: 0.5).map { gusty.windSpeed(at: $0) }
        #expect(speeds.min()! >= gusty.windSpeed)
        #expect(speeds.max()! > gusty.windSpeed + 1)
        #expect(speeds.max()! <= gusty.windSpeed + gusty.gust + 1e-9)
        #expect(calm.windSpeed(at: 3) == calm.windSpeed)
    }

    @Test func lightningOnlyInThunderstormAndDeterministic() throws {
        let clear = try Self.fx("KMRY 221656Z 27008KT 10SM CLR 16/08 A3002")
        #expect(clear.lightning(at: 12) == 0)
        #expect(clear.nextLightning(after: 0) == nil)
        let ts = try Self.fx("KMCO 221656Z 18015G28KT 3SM +TSRA BKN025CB 27/23 A2992")
        let first = try #require(ts.nextLightning(after: 0))
        #expect(first >= 7 && first <= 19)
        #expect(ts.lightning(at: first + 0.05) > 0.5)
        #expect(ts.lightning(at: first - 1) == 0)
        #expect(ts.lightning(at: first + 0.05) == ts.lightning(at: first + 0.05))
    }

    @Test func presetsMapToEffects() {
        let storm = WeatherEffects(state: WeatherPreset.storm.state(seed: 1))
        #expect(storm.precipitation == .rain)
        #expect(storm.thunderstorm)
        #expect(WeatherEffects(state: WeatherPreset.clear.state(seed: 1)).precipitation == .none)
        #expect(WeatherEffects(state: WeatherPreset.clear.state(seed: 1)).groundFog == false)
    }
}
