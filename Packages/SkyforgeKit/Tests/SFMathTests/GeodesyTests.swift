import Testing
@testable import SFMath

@Suite struct GeodesyTests {
    @Test func roundTrip10k() {
        var rng = Xoshiro256(seed: 42)
        var worst = 0.0
        for _ in 0..<10_000 {
            let g = Geodetic(latitude: rng.range(-.pi / 2, .pi / 2), longitude: rng.range(-.pi, .pi), height: rng.range(-500, 20_000))
            let p = g.toECEF()
            let back = Geodetic.fromECEF(p).toECEF()
            worst = max(worst, length(back - p))
        }
        #expect(worst < 0.001)
    }

    @Test func referencePoints() {
        let eq = Geodetic(latitudeDegrees: 0, longitudeDegrees: 0, height: 0).toECEF()
        #expect(abs(eq.x - WGS84.a) < 1e-6)
        let pole = Geodetic(latitudeDegrees: 90, longitudeDegrees: 0, height: 0).toECEF()
        #expect(abs(pole.z - WGS84.b) < 1e-6)
        let back = Geodetic.fromECEF(pole)
        #expect(abs(back.height) < 1e-3)
    }

    @Test func enuFrameUpIsUp() {
        let f = ENUFrame(origin: Geodetic(latitudeDegrees: 37.6, longitudeDegrees: -122.4, height: 10))
        let above = Geodetic(latitudeDegrees: 37.6, longitudeDegrees: -122.4, height: 1010).toECEF()
        let l = f.toLocal(ecef: above)
        #expect(abs(l.z - 1000) < 1e-6)
        #expect(abs(l.x) < 1e-6 && abs(l.y) < 1e-6)
        #expect(length(f.toECEF(local: l) - above) < 1e-6)
    }

    @Test func quaternionEulerRoundTrip() {
        let q = Quaternion(roll: 0.3, pitch: -0.2, yaw: 2.0)
        let e = q.euler
        #expect(abs(e.roll - 0.3) < 1e-12 && abs(e.pitch + 0.2) < 1e-12 && abs(e.yaw - 2.0) < 1e-12)
        let r = Quaternion(axis: SIMD3(0, 0, 1), angle: .pi / 2).rotate(SIMD3(1, 0, 0))
        #expect(length(r - SIMD3(0, 1, 0)) < 1e-12)
    }

    @Test func prngDeterministic() {
        var a = Xoshiro256(seed: 7), b = Xoshiro256(seed: 7)
        for _ in 0..<100 { #expect(a.next() == b.next()) }
        var c = SplitMix64(seed: 0)
        #expect(c.next() == 0xE220_A839_7B1D_CDAF)
    }

    @Test func noiseBoundedAndDeterministic() {
        let n = GradientNoise2D(seed: 3)
        var lo = 0.0, hi = 0.0
        for i in 0..<2000 {
            let v = n.fbm(Double(i) * 0.137, Double(i) * 0.071)
            lo = min(lo, v); hi = max(hi, v)
            #expect(v == GradientNoise2D(seed: 3).fbm(Double(i) * 0.137, Double(i) * 0.071))
        }
        #expect(lo > -1.5 && hi < 1.5 && hi - lo > 0.3)
    }
}

@Suite struct GeodesicTests {
    @Test func flindersPeakToBuninyong() {
        // Vincenty (1975) reference example on the GRS80/WGS84 ellipsoid.
        let p1 = Geodetic(latitudeDegrees: -(37 + 57.0 / 60 + 3.72030 / 3600), longitudeDegrees: 144 + 25.0 / 60 + 29.52440 / 3600, height: 0)
        let p2 = Geodetic(latitudeDegrees: -(37 + 39.0 / 60 + 10.15610 / 3600), longitudeDegrees: 143 + 55.0 / 60 + 35.38390 / 3600, height: 0)
        let r = Geodesic.inverse(p1, p2)
        #expect(abs(r.distance - 54_972.271) < 0.01)
        let brgDeg = r.initialBearing * 180 / .pi
        #expect(abs(brgDeg - (306 + 52.0 / 60 + 5.37 / 3600)) < 1e-4)
    }

    @Test func directInverseRoundTrip() {
        var rng = Xoshiro256(seed: 9)
        for _ in 0..<500 {
            let p = Geodetic(latitude: rng.range(-1.4, 1.4), longitude: rng.range(-3.1, 3.1), height: 0)
            let brg = rng.range(0, 2 * .pi), dist = rng.range(10, 2_000_000)
            let q = Geodesic.direct(p, bearing: brg, distance: dist)
            let inv = Geodesic.inverse(p, q)
            #expect(abs(inv.distance - dist) < 0.001)
        }
    }
}
