import Testing
import Foundation
@testable import SFWeather

@Suite struct SeasonsTests {
    private func northern(_ day: Double, lat: Double = 45, t: Double? = nil, snow: Bool = false) -> SeasonalConditions {
        WeatherSeason.evaluate(dayOfYear: day, latitudeDeg: lat, surfaceTemperatureC: t, snowfallRecent: snow)
    }

    @Test func declinationPeaksAtSolstices() {
        // Northern summer solstice is about day 172, winter solstice about day 355.
        #expect(abs(WeatherSeason.declinationDeg(172) - 23.44) < 0.2)
        #expect(abs(WeatherSeason.declinationDeg(355) + 23.44) < 0.2)
        #expect(abs(WeatherSeason.declinationDeg(80)) < 1.0)   // equinox
    }

    @Test func northernSeasonsFollowTheSun() {
        #expect(northern(172).season == .summer)
        #expect(northern(15).season == .winter)
        #expect(northern(80).season == .spring)
        #expect(northern(270).season == .autumn)
        #expect(northern(265).season == .summer)
    }

    @Test func southernSeasonsAreOpposite() {
        let january = WeatherSeason.evaluate(dayOfYear: 15, latitudeDeg: -35, surfaceTemperatureC: nil, snowfallRecent: false)
        let july = WeatherSeason.evaluate(dayOfYear: 190, latitudeDeg: -35, surfaceTemperatureC: nil, snowfallRecent: false)
        #expect(january.season == .summer)
        #expect(july.season == .winter)
        #expect(WeatherSeason.evaluate(dayOfYear: 90, latitudeDeg: -35, surfaceTemperatureC: nil, snowfallRecent: false).season == .autumn)
    }

    @Test func daylengthMatchesLatitude() {
        let equinox = WeatherSeason.declinationDeg(80)
        #expect(abs(WeatherSeason.dayLengthHours(latitudeDeg: 0, declinationDeg: equinox) - 12) < 0.3)
        // 60 N at the June solstice has more than 18 hours of light; 70 N in December has none.
        #expect(WeatherSeason.dayLengthHours(latitudeDeg: 60, declinationDeg: 23.44) > 18)
        #expect(WeatherSeason.dayLengthHours(latitudeDeg: 70, declinationDeg: -23.44) == 0)
        #expect(WeatherSeason.dayLengthHours(latitudeDeg: 70, declinationDeg: 23.44) == 24)
    }

    @Test func snowFollowsTemperatureAndLatitude() {
        // Denver-like latitude in the cold, and a recent snowfall, both give deep cover.
        #expect(WeatherSeason.evaluate(dayOfYear: 20, latitudeDeg: 40, surfaceTemperatureC: -10, snowfallRecent: false).snowCover > 0.95)
        // Miami-like latitude never builds a pack, even when freezing.
        #expect(WeatherSeason.evaluate(dayOfYear: 20, latitudeDeg: 25.8, surfaceTemperatureC: -5, snowfallRecent: true).snowCover == 0)
        // Warm summer day at a snowy latitude has no snow.
        #expect(northern(190, lat: 52, t: 20).snowCover == 0)
        // Cover is a fraction.
        let s = northern(10, lat: 60, t: -30, snow: true).snowCover
        #expect(s >= 0 && s <= 1)
    }

    @Test func snowWithoutTemperatureUsesSeason() {
        #expect(northern(15, lat: 55).snowCover > 0.5)
        #expect(northern(190, lat: 55).snowCover == 0)
    }

    @Test func foliageChangesThroughAutumn() {
        let earlyAutumn = northern(270)
        let lateAutumn = northern(320)
        #expect(earlyAutumn.season == .autumn)
        #expect(lateAutumn.autumnColour > earlyAutumn.autumnColour)
        #expect(lateAutumn.leafFall >= earlyAutumn.leafFall)
        #expect(northern(190).autumnColour == 0)
        #expect(northern(20).autumnColour == 0)
        #expect(northern(190).leafFall == 0)
        #expect(northern(20).leafFall == 1)   // bare canopy in winter
    }

    @Test func calendarDateMatchesDayOfYear() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!
        let fromDate = WeatherSeason.evaluate(date: date, latitudeDeg: 45, surfaceTemperatureC: nil, snowfallRecent: false)
        #expect(fromDate.season == .summer)
        #expect(abs(fromDate.solarDeclinationDeg - 23.44) < 0.3)
    }
}
