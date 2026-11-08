// SKYFORGE — Apache-2.0
// CPU preview of the volumetric cumulus layer over the physically based sky (reference images for
// the Metal cloud pass and for tuning the cloud model).
import Foundation
import SFAtmosphere

extension SkyPreview {
    /// RGB8 view from `viewHeightKm` of `model`, toward `yawDeg` from the sun azimuth, with `layer` clouds.
    public static func renderClouds(_ m: SkyModel, layer: CloudLayer, width: Int, height: Int, fovDeg: Double = 90,
                                    pitchDeg: Double = 10, yawDeg: Double = 0, steps: Int = 96, exposure: Double? = nil) -> [UInt8] {
        let ex = exposure ?? autoExposure(m)
        let sd = m.sunDirection
        let sunAz = atan2(sd.z, sd.x)
        let yaw = sunAz + yawDeg * .pi / 180, pitch = pitchDeg * .pi / 180
        // ENU frame (x east, y north, z up) ↔ sky frame (x, y up, z).
        let fwd = SIMD3<Double>(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
        let right = SIMD3<Double>(sin(yaw), -cos(yaw), 0)
        let up = SIMD3<Double>(right.y * fwd.z - right.z * fwd.y, right.z * fwd.x - right.x * fwd.z, right.x * fwd.y - right.y * fwd.x)
        let tanH = tan(fovDeg * .pi / 360), tanV = tanH * Double(height) / Double(width)
        let toSun = SIMD3<Float>(Float(sd.x), Float(sd.z), Float(sd.y))
        let sunT = m.sunTransmittance
        var eSky = V3.zero
        for i in 0..<64 {
            let ct = (Double(i % 8) + 0.5) / 8, az = Double(i / 8) / 8 * 2 * .pi
            let st = (1 - ct * ct).squareRoot()
            eSky += m.radiance(V3(st * cos(az), ct, st * sin(az)), includeSun: false) * ct
        }
        eSky *= 2 * .pi / 64
        let sunUp = max(0, sd.y)
        let albedo = V3(0.16, 0.20, 0.11)
        let eGround = sunT * sunUp + eSky
        func f3(_ v: V3) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        let sun = f3(sunT) / .pi, skyAmb = f3(eSky) / .pi, groundAmb = f3(albedo * eGround) / (.pi * .pi)
        let camZ = Float(m.viewHeightKm * 1_000)
        var out = [UInt8](repeating: 0, count: width * height * 3)
        out.withUnsafeMutableBufferPointer { buf in
            let base = UnsafeSendablePointer(buf.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let sx = (2 * (Double(x) + 0.5) / Double(width) - 1) * tanH
                    let sy = (1 - 2 * (Double(y) + 0.5) / Double(height)) * tanV
                    var d = fwd + right * sx + up * sy
                    d /= (d * d).sum().squareRoot()
                    let skyDir = V3(d.x, d.z, d.y)
                    var L: V3, maxDist: Float
                    if d.z >= -0.0005 {
                        L = m.radiance(skyDir); maxDist = .infinity
                    } else {
                        let dist = min(400, m.viewHeightKm / -d.z)
                        let (ins, t) = m.aerialPerspective(skyDir, distanceKm: dist, steps: 10)
                        L = albedo / .pi * eGround * t + ins
                        maxDist = Float(dist * 1_000)
                    }
                    let c = VolumetricClouds.march(origin: SIMD3(0, 0, camZ), dir: SIMD3(Float(d.x), Float(d.y), Float(d.z)),
                                                   maxDist: maxDist, layer: layer, toSun: toSun, sun: sun, skyAmbient: skyAmb,
                                                   groundAmbient: groundAmb, steps: steps, jitter: VolumetricClouds.jitter(x: x, y: y))
                    if c.transmittance < 1 {
                        let (ins, t) = m.aerialPerspective(skyDir, distanceKm: Double(c.depth) / 1_000, steps: 6)
                        let lc = V3(Double(c.radiance.x), Double(c.radiance.y), Double(c.radiance.z))
                        L = L * Double(c.transmittance) + lc * t + ins * (1 - Double(c.transmittance))
                    }
                    let i = 3 * (y * width + x)
                    for k in 0..<3 { base.p[i + k] = UInt8((pow(aces(L[k] * ex), 1 / 2.2) * 255).rounded()) }
                }
            }
        }
        return out
    }
}
