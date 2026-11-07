import Testing
@testable import SFAtmosphere

@Suite struct ISATests {
    // Reference values: US Standard Atmosphere 1976 tables (geometric altitude).
    @Test(arguments: [
        (0.0, 288.150, 101_325.0, 1.2250),
        (1_000.0, 281.651, 89_874.6, 1.1117),
        (5_000.0, 255.676, 54_048.3, 0.73643),
        (11_000.0, 216.774, 22_699.9, 0.36480),
        (20_000.0, 216.650, 5_529.3, 0.088910),
        (32_000.0, 228.490, 889.06, 0.013555),
    ])
    func tableValues(z: Double, t: Double, p: Double, rho: Double) {
        let s = ISA.state(geometricAltitude: z)
        #expect(abs(s.temperature - t) / t < 0.001)
        #expect(abs(s.pressure - p) / p < 0.001)
        #expect(abs(s.density - rho) / rho < 0.001)
    }

    @Test func pressureAltitudeInverse() {
        for z in stride(from: 0.0, through: 15_000, by: 500) {
            let s = ISA.state(geometricAltitude: z)
            let h = ISA.pressureAltitude(pressure: s.pressure)
            #expect(abs(h - ISA.geopotential(fromGeometric: z)) < 0.5)
        }
    }

    @Test func casTasRoundTrip() {
        let s = ISA.state(geometricAltitude: 3_000)
        let tas = 60.0
        let cas = Airspeed.calibratedAirspeed(trueAirspeed: tas, atmosphere: s)
        #expect(cas < tas)
        #expect(abs(Airspeed.trueAirspeed(calibratedAirspeed: cas, atmosphere: s) - tas) < 1e-6)
        let sl = ISA.state(geometricAltitude: 0)
        #expect(abs(Airspeed.calibratedAirspeed(trueAirspeed: 100, atmosphere: sl) - 100) < 1e-6)
    }
}
