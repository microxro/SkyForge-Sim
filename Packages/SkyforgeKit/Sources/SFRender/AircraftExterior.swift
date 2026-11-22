// SKYFORGE — Apache-2.0
// Aircraft exterior detail (round 5): CPU reference + parameters for rivets/panel normals, clearcoat,
// dirt and exhaust staining, glass rain, FAA/ICAO exterior lights, propeller blur, heat shimmer,
// contrails and wingtip vortices. Pure Swift (Linux-testable); the MSL twin is `AircraftExteriorShaders`.
// Body axes: x forward, y right, z down, origin at the CG (same as `AircraftLivery`).
import Foundation

/// Quality tier for exterior effects (same four names as the device tiers).
public enum ExteriorTier: String, Sendable, CaseIterable { case low, medium, high, ultra }

public struct AircraftExteriorKnobs: Sendable, Equatable {
    public var rivets: Bool, clearcoat: Bool, dirt: Bool, rain: Bool
    public var lightGlow: Bool, propBlurSamples: Int, heatShimmer: Bool, vortices: Bool
    /// Distance (m) beyond which per-pixel surface detail is skipped.
    public var detailDistance: Float
    /// Rain streak layers on glass.
    public var rainLayers: Int

    public static func make(_ t: ExteriorTier) -> AircraftExteriorKnobs {
        switch t {
        case .low:   return .init(rivets: false, clearcoat: false, dirt: true, rain: false, lightGlow: true, propBlurSamples: 1, heatShimmer: false, vortices: false, detailDistance: 30, rainLayers: 0)
        case .medium: return .init(rivets: true, clearcoat: false, dirt: true, rain: true, lightGlow: true, propBlurSamples: 4, heatShimmer: false, vortices: false, detailDistance: 60, rainLayers: 1)
        case .high:  return .init(rivets: true, clearcoat: true, dirt: true, rain: true, lightGlow: true, propBlurSamples: 8, heatShimmer: true, vortices: true, detailDistance: 100, rainLayers: 2)
        case .ultra: return .init(rivets: true, clearcoat: true, dirt: true, rain: true, lightGlow: true, propBlurSamples: 16, heatShimmer: true, vortices: true, detailDistance: 150, rainLayers: 3)
        }
    }
}

// MARK: Exterior lights (14 CFR 23.1385-1401 colours; AC 20-30/ SAE AS8037 flash rates)

public enum ExteriorLightKind: Sendable { case position, strobe, beacon }

public struct ExteriorLight: Sendable {
    public var name: String
    public var kind: ExteriorLightKind
    /// Body-axes position (m).
    public var position: SIMD3<Float>
    /// Linear RGB. Red port, green starboard, white tail/strobe, red beacon (aviation red/green/white).
    public var colour: SIMD3<Float>
    /// Phase offset (s) so strobes are not perfectly simultaneous in the sim.
    public var phase: Float
    /// Peak luminous scale for the glow sprite (HDR multiplier before exposure).
    public var peak: Float
}

public enum AircraftExteriorLights {
    public static let red = SIMD3<Float>(1.0, 0.02, 0.01), green = SIMD3<Float>(0.0, 0.85, 0.20), white = SIMD3<Float>(1.0, 0.96, 0.88)

    /// Strobe cycle: a double flash every 1.2 s (50 flashes/min, inside the 40-100 fpm band).
    public static let strobePeriod: Float = 1.2
    /// Flash start offsets and length inside the cycle (s): two 60 ms flashes 150 ms apart.
    public static let strobeFlashes: [(start: Float, length: Float)] = [(0.0, 0.06), (0.15, 0.06)]
    /// Red beacon: 60 cycles/min, each a raised-cosine sweep of the rotating mirror lasting 0.35 s of the 1 s cycle.
    public static let beaconPeriod: Float = 1.0, beaconWidth: Float = 0.35

    /// SF-1 layout (wingtips ±5.5 m, tail cone at x = -5.6, beacon on the fin top).
    public static let sf1: [ExteriorLight] = [
        .init(name: "left position", kind: .position, position: SIMD3(-0.2, -5.45, -1.0), colour: red, phase: 0, peak: 6),
        .init(name: "right position", kind: .position, position: SIMD3(-0.2, 5.45, -1.0), colour: green, phase: 0, peak: 6),
        .init(name: "tail position", kind: .position, position: SIMD3(-5.65, 0, -0.52), colour: white, phase: 0, peak: 5),
        .init(name: "left strobe", kind: .strobe, position: SIMD3(-0.3, -5.5, -1.0), colour: white, phase: 0.00, peak: 60),
        .init(name: "right strobe", kind: .strobe, position: SIMD3(-0.3, 5.5, -1.0), colour: white, phase: 0.00, peak: 60),
        .init(name: "tail strobe", kind: .strobe, position: SIMD3(-5.7, 0, -0.55), colour: white, phase: 0.04, peak: 40),
        .init(name: "beacon", kind: .beacon, position: SIMD3(-5.3, 0, -2.45), colour: red, phase: 0, peak: 25),
    ]

    /// 0...1 emission of `light` at sim time `t` seconds (position lights are steady).
    public static func intensity(_ light: ExteriorLight, time t: Float) -> Float {
        switch light.kind {
        case .position: return 1
        case .strobe:
            let c = axPositiveMod(t + light.phase, strobePeriod)
            for f in strobeFlashes where c >= f.start && c < f.start + f.length {
                // Short rise/fall so the flash is not a hard 1-frame square at 60 Hz.
                let u = (c - f.start) / f.length
                return min(1, min(u, 1 - u) * 6)
            }
            return 0
        case .beacon:
            let c = axPositiveMod(t + light.phase, beaconPeriod)
            if c >= beaconWidth { return 0.02 }                    // faint reflector glint between sweeps
            return 0.5 - 0.5 * cos(2 * Float.pi * c / beaconWidth)
        }
    }

    /// Angular size (pixels) of the glow sprite: grows with intensity, shrinks with distance, floored so a
    /// distant light stays a visible point, capped so bloom does not swamp the airframe.
    public static func glowRadiusPixels(peak: Float, intensity: Float, distance: Float, pixelsPerRadian: Float) -> Float {
        guard intensity > 0.001 else { return 0 }
        let sourceRadius: Float = 0.05 * (0.5 + 0.5 * intensity) * (1 + peak.squareRoot() * 0.3)   // m
        let px = sourceRadius / max(distance, 1) * pixelsPerRadian * 6
        return min(max(px, 1.5 * intensity), 48)
    }

    /// Position lights are visible out to the regulatory 2 NM / strobes 3 NM; beyond, the glow fades.
    public static func visibilityFade(_ light: ExteriorLight, distance: Float) -> Float {
        let range: Float = light.kind == .position ? 3_704 : 5_556
        return 1 - axSmooth(range * 0.8, range * 1.4, distance)
    }
}

// MARK: Surface detail

public enum AircraftSurfaceDetail {
    /// Rivet grid: rows every `pitch` m; each rivet a dome of radius `radius`. Returns dome height 0...1 and the
    /// surface-normal tilt (dx, dy) in the (u, v) plane, matching the MSL `ax_rivet`.
    public static func rivet(u: Float, v: Float, pitch: Float = 0.032, radius: Float = 0.0045, footprint fp: Float) -> (height: Float, tilt: SIMD2<Float>, fade: Float) {
        let fade = max(0, min(1, 1 - fp / (pitch * 0.45)))     // alias-free: gone when a pixel spans ~half a pitch
        guard fade > 0 else { return (0, .zero, 0) }
        let cu = (u / pitch).rounded() * pitch, cv = (v / pitch).rounded() * pitch
        let du = u - cu, dv = v - cv
        let r = (du * du + dv * dv).squareRoot() / radius
        guard r < 1 else { return (0, .zero, fade) }
        let h = (1 - r * r).squareRoot()
        let slope = r / max(h, 0.25)
        let inv = r > 1e-4 ? 1 / (r * radius) : 0
        return (h, SIMD2(-du * inv, -dv * inv) * slope * fade, fade)
    }

    /// Exhaust/oil staining: a soot streak trailing aft from the exhaust outlet on the belly and lower cowl,
    /// widening with distance, plus oil weeping under the cowl. 0 = clean, 1 = dark. `hours` ages the airframe.
    public static func exhaustStain(body p: SIMD3<Float>, hours: Float = 200) -> Float {
        let age = min(1, hours / 400)
        let aft = max(0, 1.9 - p.x)                       // metres behind the outlet (x = 1.9)
        guard p.x < 1.9, p.z > 0.1 else { return 0 }       // lower half only
        let width = 0.08 + 0.11 * aft
        let across = abs(p.y - 0.05 * aft) / width        // pushed slightly outboard by prop slipstream swirl
        let lateral = max(0, 1 - across * across)
        let decay = exp(-aft / 2.6)
        return min(1, 0.85 * age * lateral * decay)
    }

    /// Leading-edge bug/dirt and belly grime: a smooth 0...1 darkening that grows with age.
    public static func dirt(body p: SIMD3<Float>, hours: Float = 200) -> Float {
        let age = min(1, hours / 400)
        let belly = axSmooth(0.1, 0.35, p.z) * 0.35
        let nose = axSmooth(2.0, 2.5, p.x) * 0.25               // cowl and spinner area: bugs, oil mist
        return min(1, (belly + nose) * age) + exhaustStain(body: p, hours: hours) * 0.9
    }

    /// Clearcoat: dielectric Fresnel (F0 = 0.04) of the lacquer layer at `cosTheta`.
    public static func clearcoatFresnel(cosTheta: Float) -> Float {
        let m = pow(1 - max(0, min(1, cosTheta)), 5)
        return 0.04 + 0.96 * m
    }

    /// Energy kept by the base layer under the clearcoat (1 - coat reflectance).
    public static func baseEnergy(cosTheta: Float, coat: Float = 1) -> Float { 1 - coat * clearcoatFresnel(cosTheta: cosTheta) }
}

// MARK: Rain on glass

public enum AircraftRain {
    /// Fraction of the canopy covered by water (0...1) from rain rate (mm/h) and a screen dry-off from airspeed.
    public static func coverage(rainRate: Float, airspeed: Float) -> Float {
        guard rainRate > 0 else { return 0 }
        let wet = min(1, rainRate / 12)
        let blowOff = axSmooth(25, 65, airspeed)       // above ~65 m/s drops are swept away as streaks
        return min(1, wet * (1 - 0.35 * blowOff) + 0.0)
    }

    /// Direction (unit, in the canopy's UV plane, +v = aft) in which a drop is dragged: aft when moving,
    /// downward on a parked aircraft. Returns the angle in radians from straight down.
    public static func streakAngle(airspeed: Float) -> Float { axSmooth(2, 40, airspeed) * (Float.pi / 2 * 0.92) }

    /// Streak length (m on the glass) from airspeed: longer and thinner when faster.
    public static func streakLength(airspeed: Float) -> Float { 0.012 + 0.28 * axSmooth(5, 70, airspeed) }
}

// MARK: Propeller blur and heat

public enum PropellerBlur {
    /// Fraction of the disc area the blades cover instantaneously (solidity): blades × chord / (π R).
    public static func solidity(blades: Int, chord: Float = 0.11, radius: Float = 0.95) -> Float { min(1, Float(blades) * chord / (Float.pi * radius)) }

    /// Time-averaged disc opacity for a camera shutter `shutter` s at `rpm`: the swept angle ratio of a blade.
    /// At rest (angle swept small) blades are opaque; as the sweep grows past the blade spacing the disc
    /// becomes a uniform translucent veil of opacity = solidity.
    public static func discOpacity(rpm: Float, blades: Int, shutter: Float = 1.0 / 60) -> Float {
        let sweep = abs(rpm) / 60 * shutter * 2 * Float.pi            // rad swept in one exposure
        let spacing = 2 * Float.pi / Float(max(blades, 1))
        let veil = solidity(blades: blades)
        let blur = axSmooth(0.15 * spacing, 1.0 * spacing, sweep)
        return veil + (1 - blur) * max(0, 0.9 - veil)
    }

    /// Apparent blade angular rate (rad/s) after temporal aliasing at `fps` (wagon-wheel effect). Within +-half of
    /// the blade-passing rate.
    public static func aliasedRate(rpm: Float, blades: Int, fps: Float) -> Float {
        let passing = rpm / 60 * Float(blades)                         // blade passes per second
        let folded = passing - fps * (passing / fps).rounded()         // fold into (-fps/2, fps/2]
        return folded / Float(blades) * 2 * Float.pi
    }
}

public enum HeatShimmer {
    /// UV displacement amplitude (pixels) behind the exhaust at `distance` m aft and `lateral` m off axis,
    /// scaled by throttle 0...1. Zero on the ground-idle-free case and beyond ~6 m.
    public static func amplitude(distanceAft d: Float, lateral l: Float, throttle: Float) -> Float {
        guard d > 0 else { return 0 }
        let plume = exp(-d / 2.2) * max(0, 1 - (l / (0.25 + 0.18 * d)) * (l / (0.25 + 0.18 * d)))
        return 3.0 * min(1, max(0, throttle)) * plume * axSmooth(0, 0.3, d)
    }
}

// MARK: Contrails and wingtip vortices

public enum ContrailModel {
    /// Simplified Schmidt-Appleman: persistent contrails need very cold, near-ice-saturated air.
    /// `temperatureC` ambient, `relativeHumidityIce` as a ratio (1 = ice saturation), `jet` false for a piston trainer.
    public static func formation(temperatureC: Float, relativeHumidityIce: Float, jet: Bool) -> Float {
        let cold = 1 - axSmooth(-45, -37, temperatureC)         // threshold ~ -40 °C for kerosene exhaust
        let moist = axSmooth(0.8, 1.05, relativeHumidityIce)
        return cold * moist * (jet ? 1 : 0.15)
    }

    /// Contrail age (s) -> optical thickness scale 0...1: forms ~0.5 s behind, then spreads and thins.
    public static func opacity(age: Float, persistence: Float) -> Float {
        guard age > 0.3 else { return 0 }
        let rise = axSmooth(0.3, 2.0, age)
        return rise * exp(-age / (20 + 280 * persistence)) * persistence
    }

    /// Radius (m) of the spread contrail after `age` s (vortex pair descends and diffuses).
    public static func radius(age: Float) -> Float { 3 + 0.9 * age.squareRoot() * 4 + 0.05 * age }
}

public enum WingtipVortex {
    /// Circulation Γ (m²/s) of a wing trailing vortex: L / (ρ V b') with b' = π/4 · span (elliptical loading).
    public static func circulation(lift: Float, airDensity: Float, airspeed: Float, span: Float) -> Float {
        let b = Float.pi / 4 * span
        return lift / max(airDensity * max(airspeed, 1) * b, 1e-3)
    }

    /// Visible condensation (0...1): core static pressure drop ~ ρ (Γ / (2π r_c))² / 2 in Pa; visible when it
    /// cools the core past dew point, i.e. in humid air under high load.
    public static func visibility(circulation g: Float, airDensity rho: Float, relativeHumidity rh: Float, coreRadius rc: Float = 0.05) -> Float {
        let v = g / (2 * Float.pi * rc)
        let dp = 0.5 * rho * v * v                                   // Pa
        let need = (1 - min(max(rh, 0), 1)) * 2_500                 // drier air needs a deeper pressure drop
        return axSmooth(need, need * 1.5 + 50, dp)
    }
}

// MARK: Helpers

@inline(__always) func axPositiveMod(_ x: Float, _ m: Float) -> Float { let r = x.truncatingRemainder(dividingBy: m); return r < 0 ? r + m : r }
@inline(__always) func axSmooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
}
