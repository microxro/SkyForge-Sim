// SKYFORGE — Apache-2.0
// Night sky model: sun/moon ephemeris (low precision), moon phase, procedural star field with Milky Way
// bias, twilight tuning on top of the Hillaire LUTs, and airglow. Pure Swift, platform independent
// (tested on Linux). The GPU side lives in Shaders/NightShaders.swift.
import Foundation
import SFMath

/// Quality knobs for everything in the night pass.
public enum NightTier: String, Sendable, CaseIterable {
    case low, medium, high, ultra
    public var starCount: Int { switch self { case .low: 1_500; case .medium: 3_500; case .high: 6_500; case .ultra: 9_000 } }
    /// Faintest magnitude generated (the sky limiting magnitude then fades it in/out at runtime).
    public var starLimitMagnitude: Float { switch self { case .low: 4.5; case .medium: 5.3; case .high: 6.0; case .ultra: 6.5 } }
    public var maxLightSprites: Int { switch self { case .low: 4_000; case .medium: 12_000; case .high: 30_000; case .ultra: 64_000 } }
    public var cityCellBudget: Int { switch self { case .low: 9; case .medium: 25; case .high: 49; case .ultra: 81 } }
    public var milkyWay: Bool { self != .low }
    public var moonSurfaceDetail: Bool { self == .high || self == .ultra }
    /// Minimum light sprite size in pixels (below this the sprite keeps size and loses energy, see `LightSprite`).
    public var minSpritePixels: Float { switch self { case .low: 2.0; case .medium: 1.8; case .high: 1.6; case .ultra: 1.5 } }
}

public enum Astro {
    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func wrap360(_ d: Double) -> Double { let r = d.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }

    /// Days since J2000.0 (2000-01-01 12:00 UT) from a Unix timestamp (UTC seconds).
    public static func daysSinceJ2000(unix: Double) -> Double { unix / 86_400 + 2_440_587.5 - 2_451_545.0 }

    public struct Equatorial: Sendable, Equatable { public var raDeg: Double; public var decDeg: Double }

    /// Unit vector in the equatorial frame (x to RA 0, z to the celestial pole).
    public static func unitVector(_ e: Equatorial) -> SIMD3<Double> {
        let a = rad(e.raDeg), d = rad(e.decDeg)
        return SIMD3(cos(d) * cos(a), cos(d) * sin(a), sin(d))
    }

    static func eclipticToEquatorial(lonDeg: Double, latDeg: Double, d: Double) -> Equatorial {
        let eps = rad(23.439 - 0.000_000_4 * d), l = rad(lonDeg), b = rad(latDeg)
        let x = cos(b) * cos(l)
        let y = cos(b) * sin(l) * cos(eps) - sin(b) * sin(eps)
        let z = cos(b) * sin(l) * sin(eps) + sin(b) * cos(eps)
        return Equatorial(raDeg: wrap360(atan2(y, x) * 180 / .pi), decDeg: asin(max(-1, min(1, z))) * 180 / .pi)
    }

    public static func sunEcliptic(d: Double) -> Double {
        let L = 280.460 + 0.985_647_4 * d, g = rad(357.528 + 0.985_600_3 * d)
        return wrap360(L + 1.915 * sin(g) + 0.020 * sin(2 * g))
    }
    public static func sun(d: Double) -> Equatorial { eclipticToEquatorial(lonDeg: sunEcliptic(d: d), latDeg: 0, d: d) }

    /// Moon ecliptic longitude / latitude (Astronomical Almanac low-precision series, ~0.3 deg).
    public static func moonEcliptic(d: Double) -> (lon: Double, lat: Double) {
        let Lp = 218.316 + 13.176_396 * d, M = rad(134.963 + 13.064_993 * d), F = rad(93.272 + 13.229_350 * d)
        return (wrap360(Lp + 6.289 * sin(M)), 5.128 * sin(F))
    }
    public static func moon(d: Double) -> Equatorial {
        let m = moonEcliptic(d: d)
        return eclipticToEquatorial(lonDeg: m.lon, latDeg: m.lat, d: d)
    }

    public struct MoonPhase: Sendable, Equatable {
        /// 0 new ... 0.5 full ... 1 new again.
        public var cycle: Double
        /// Illuminated fraction 0...1.
        public var illuminated: Double
        /// Sun-moon-observer phase angle in degrees (0 full, 180 new).
        public var phaseAngleDeg: Double
        public var waxing: Bool { cycle < 0.5 }
    }
    public static func moonPhase(d: Double) -> MoonPhase {
        let m = moonEcliptic(d: d)
        let dl = wrap360(m.lon - sunEcliptic(d: d))
        let cosPsi = cos(rad(m.lat)) * cos(rad(dl))      // cos of elongation
        let psi = acos(max(-1, min(1, cosPsi))) * 180 / .pi
        return MoonPhase(cycle: dl / 360, illuminated: (1 - cosPsi) / 2, phaseAngleDeg: 180 - psi)
    }

    /// Local sidereal time in degrees.
    public static func localSiderealDeg(d: Double, lonDeg: Double) -> Double {
        wrap360((18.697_374_558 + 24.065_709_824_419_08 * d) * 15 + lonDeg)
    }

    /// Rotation of an equatorial unit vector into local East/North/Up.
    public static func equatorialToENU(_ v: SIMD3<Double>, latDeg: Double, lstDeg: Double) -> SIMD3<Double> {
        let L = rad(lstDeg), p = rad(latDeg)
        let cosDcosH = v.x * cos(L) + v.y * sin(L)
        let cosDsinH = v.x * sin(L) - v.y * cos(L)
        return SIMD3(-cosDsinH, v.z * cos(p) - cosDcosH * sin(p), v.z * sin(p) + cosDcosH * cos(p))
    }
    /// The three rows (E, N, U) as float4 for the GPU: dirENU = (dot(E.xyz,d), dot(N.xyz,d), dot(U.xyz,d)).
    public static func equatorialToENURows(latDeg: Double, lstDeg: Double) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let x = equatorialToENU(SIMD3(1, 0, 0), latDeg: latDeg, lstDeg: lstDeg)
        let y = equatorialToENU(SIMD3(0, 1, 0), latDeg: latDeg, lstDeg: lstDeg)
        let z = equatorialToENU(SIMD3(0, 0, 1), latDeg: latDeg, lstDeg: lstDeg)
        func row(_ i: Int) -> SIMD4<Float> { SIMD4(Float(x[i]), Float(y[i]), Float(z[i]), 0) }
        return (row(0), row(1), row(2))
    }
    public static func elevationDeg(_ enu: SIMD3<Double>) -> Double { asin(max(-1, min(1, enu.z))) * 180 / .pi }
}

// MARK: Star field

public struct Star: Sendable, Equatable {
    /// Unit vector, equatorial frame.
    public var direction: SIMD3<Float>
    public var magnitude: Float
    /// Linear RGB tint (max component 1).
    public var color: SIMD3<Float>
}

public enum StarField {
    /// North galactic pole and galactic centre (J2000) in the equatorial frame.
    public static let galacticPole = Astro.unitVector(.init(raDeg: 192.859_5, decDeg: 27.128_3))
    public static let galacticCentre = Astro.unitVector(.init(raDeg: 266.405, decDeg: -28.936))

    /// Approximate blackbody tint from B-V colour index.
    public static func tint(bMinusV bv: Float) -> SIMD3<Float> {
        let t = max(-0.3, min(1.9, bv))
        let r: Float = t < 0.4 ? 0.62 + 0.55 * (t + 0.3) : 1
        let g: Float = t < 0.4 ? 0.74 + 0.40 * (t + 0.3) : max(0.55, 1.0 - 0.28 * (t - 0.4))
        let b: Float = t < 0.4 ? 1 : max(0.25, 1.0 - 0.52 * (t - 0.4))
        let m = max(r, g, b)
        return SIMD3(min(1, r / m), min(1, g / m), min(1, b / m))
    }

    /// Density of the Milky Way band (0...1) at an equatorial direction; brightest toward the centre.
    public static func milkyWayDensity(_ dir: SIMD3<Double>) -> Double {
        let sinB = dir.x * galacticPole.x + dir.y * galacticPole.y + dir.z * galacticPole.z
        let b = asin(max(-1, min(1, sinB))) * 180 / .pi
        let band = exp(-(b / 11) * (b / 11))
        let c = dir.x * galacticCentre.x + dir.y * galacticCentre.y + dir.z * galacticCentre.z
        return band * (0.55 + 0.45 * max(0, c))
    }

    /// Deterministic catalogue. Magnitudes follow N(<m) ~ 10^(0.5 m); about a third of stars are drawn toward
    /// the galactic band by rejection so the Milky Way reads even where the shader band is off.
    public static func generate(tier: NightTier, seed: UInt64 = 0x57A8_F1E1D) -> [Star] {
        var rng = Xoshiro256(seed: seed)
        let mMin: Double = -1.0, mMax = Double(tier.starLimitMagnitude)
        let span = pow(10, 0.5 * (mMax - mMin)) - 1
        var out: [Star] = []
        out.reserveCapacity(tier.starCount)
        while out.count < tier.starCount {
            let z = rng.range(-1, 1), a = rng.range(0, 2 * .pi)
            let r = (1 - z * z).squareRoot()
            let dir = SIMD3(r * cos(a), r * sin(a), z)
            let biased = out.count % 3 == 0
            if biased && rng.unit() > milkyWayDensity(dir) * 0.9 + 0.05 { continue }
            let m = mMin + log10(1 + rng.unit() * span) / 0.5
            // B-V: roughly normal around 0.6, clipped.
            let bv = Float(0.6 + (rng.unit() + rng.unit() + rng.unit() - 1.5) * 1.1)
            out.append(Star(direction: SIMD3(Float(dir.x), Float(dir.y), Float(dir.z)), magnitude: Float(m), color: tint(bMinusV: bv)))
        }
        return out
    }

    /// GPU packing: two float4 per star: (dir.xyz, magnitude), (rgb, 0).
    public static func pack(_ stars: [Star]) -> [SIMD4<Float>] {
        var o: [SIMD4<Float>] = []
        o.reserveCapacity(stars.count * 2)
        for s in stars {
            o.append(SIMD4(s.direction, s.magnitude))
            o.append(SIMD4(s.color, 0))
        }
        return o
    }
}

// MARK: Twilight, moonlight, airglow

public struct TwilightGrade: Sendable, Equatable {
    /// Warm colour pushed into the sun-side horizon band (linear RGB, already scaled by strength).
    public var horizonWarm: SIMD3<Float>
    /// Cool/purple "belt of Venus" tint for the anti-solar horizon.
    public var antiSolarTint: SIMD3<Float>
    /// Multiplier on LUT-sky saturation (twilight skies read more saturated to the eye).
    public var saturation: Float
    /// Exposure multiplier that eases the scotopic transition (1 in daylight, up to ~ 40 deep night).
    public var exposureBoost: Float
}

public enum NightModel {
    static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
    }

    /// Faintest visible star magnitude from the sun elevation (civil / nautical / astronomical twilight table).
    public static func limitingMagnitude(sunElevationDeg e: Float) -> Float {
        let table: [(Float, Float)] = [(6, -2), (0, -1), (-6, 1.5), (-12, 4.5), (-18, 6.5)]
        if e >= table[0].0 { return table[0].1 }
        for i in 1..<table.count where e >= table[i].0 {
            let (e0, m0) = table[i - 1], (e1, m1) = table[i]
            return m0 + (m1 - m0) * (e - e0) / (e1 - e0)
        }
        return 6.5
    }

    /// 0 (day) ... 1 (full dark): drives star/airglow/Milky Way overall fade.
    public static func darkness(sunElevationDeg e: Float) -> Float { smooth(-1, -16, e) }

    public static func twilight(sunElevationDeg e: Float) -> TwilightGrade {
        // Strongest warm band right around sunset, fading out by -10 deg.
        let warm = smooth(-10, -1, e) * (1 - smooth(4, 12, e))
        let belt = smooth(-14, -2, e) * (1 - smooth(-4, -1, e) * 0.2) * (1 - smooth(-16, -10, e))
        return TwilightGrade(
            horizonWarm: SIMD3(1.00, 0.42, 0.12) * warm,
            antiSolarTint: SIMD3(0.55, 0.38, 0.62) * belt * 0.5,
            saturation: 1 + 0.35 * warm,
            exposureBoost: 1 + 39 * smooth(-3, -14, e))
    }

    /// Moon illuminance on the ground (lux), Krisciunas & Schaefer style phase function times altitude term.
    public static func moonlightLux(phaseAngleDeg a: Double, elevationDeg el: Double) -> Double {
        guard el > 0 else { return 0 }
        let mag = 0.026 * abs(a) + 4e-9 * pow(abs(a), 4)
        let full = 0.267 * pow(10, -0.4 * mag)
        return full * pow(sin(el * .pi / 180), 0.8)
    }

    /// Van Rhijn enhancement of the 90 km airglow layer toward the horizon (1 at zenith).
    public static func airglowEnhancement(elevationDeg el: Float) -> Float {
        let z = (90 - max(el, -5)) * .pi / 180
        let k: Float = 6371 / (6371 + 90)
        return 1 / (1 - k * k * sin(z) * sin(z)).squareRoot()
    }
    /// Zenith airglow colour (557.7 nm green + 630 nm red + faint blue continuum), linear RGB, unit-ish.
    public static let airglowColor = SIMD3<Float>(0.10, 0.55, 0.22)

    /// Background sky radiance floor (arbitrary scene units, 1 = starlit zenith) at night.
    public static func skyFloor(sunElevationDeg e: Float, moonLux: Double) -> Float {
        1 + Float(min(moonLux, 0.3) * 40) * darkness(sunElevationDeg: e)
    }
}

/// Everything the night pass needs for one frame (CPU side).
public struct NightSkyState: Sendable, Equatable {
    public var sunENU: SIMD3<Double>
    public var moonENU: SIMD3<Double>
    public var moonPhase: Astro.MoonPhase
    public var sunElevationDeg: Float
    public var moonElevationDeg: Float
    public var limitingMagnitude: Float
    public var darkness: Float
    public var moonlightLux: Double
    public var lstDeg: Double
    public var rows: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    public var twilight: TwilightGrade

    public static func == (a: NightSkyState, b: NightSkyState) -> Bool {
        a.sunENU == b.sunENU && a.moonENU == b.moonENU && a.moonPhase == b.moonPhase && a.lstDeg == b.lstDeg
    }

    public init(unix: Double, latDeg: Double, lonDeg: Double) {
        let d = Astro.daysSinceJ2000(unix: unix)
        lstDeg = Astro.localSiderealDeg(d: d, lonDeg: lonDeg)
        sunENU = Astro.equatorialToENU(Astro.unitVector(Astro.sun(d: d)), latDeg: latDeg, lstDeg: lstDeg)
        moonENU = Astro.equatorialToENU(Astro.unitVector(Astro.moon(d: d)), latDeg: latDeg, lstDeg: lstDeg)
        moonPhase = Astro.moonPhase(d: d)
        sunElevationDeg = Float(Astro.elevationDeg(sunENU))
        moonElevationDeg = Float(Astro.elevationDeg(moonENU))
        limitingMagnitude = NightModel.limitingMagnitude(sunElevationDeg: sunElevationDeg)
        darkness = NightModel.darkness(sunElevationDeg: sunElevationDeg)
        moonlightLux = NightModel.moonlightLux(phaseAngleDeg: moonPhase.phaseAngleDeg, elevationDeg: Double(moonElevationDeg))
        rows = Astro.equatorialToENURows(latDeg: latDeg, lstDeg: lstDeg)
        twilight = NightModel.twilight(sunElevationDeg: sunElevationDeg)
    }

    /// Galactic pole / centre in the local ENU frame for the shader.
    public func galacticENU() -> (pole: SIMD3<Float>, centre: SIMD3<Float>) {
        func f(_ v: SIMD3<Double>) -> SIMD3<Float> {
            let r = rows
            return SIMD3(Float(v.x) * r.0.x + Float(v.y) * r.0.y + Float(v.z) * r.0.z,
                         Float(v.x) * r.1.x + Float(v.y) * r.1.y + Float(v.z) * r.1.z,
                         Float(v.x) * r.2.x + Float(v.y) * r.2.y + Float(v.z) * r.2.z)
        }
        return (f(StarField.galacticPole), f(StarField.galacticCentre))
    }
}
