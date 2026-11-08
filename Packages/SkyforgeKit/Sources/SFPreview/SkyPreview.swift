// SKYFORGE — Apache-2.0
// Renders the physically based sky (SFAtmosphere.SkyModel) through a pinhole camera for previews:
// sky above the horizon, a Lambertian ground with aerial perspective below it, ACES tone mapping.
import Foundation
import SFAtmosphere

public enum SkyPreview {
    static func aces(_ x: Double) -> Double {
        let a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14
        return min(1, max(0, (x * (a * x + b)) / (x * (c * x + d) + e)))
    }

    /// Exposure that maps the mean upper-hemisphere luminance to mid-grey.
    public static func autoExposure(_ m: SkyModel) -> Double {
        var y = 0.0, n = 0
        let lut = m.skyView
        for j in 0..<(lut.height / 2) {
            for i in 0..<lut.width {
                let c = lut[i, j]
                y += 0.2126 * Double(c.x) + 0.7152 * Double(c.y) + 0.0722 * Double(c.z); n += 1
            }
        }
        return min(400, max(2, 0.16 / max(1e-6, y / Double(n))))
    }

    /// RGB8 image looking toward `yawDeg` (0 = the sun's azimuth) with horizontal field of view `fovDeg`.
    public static func render(_ m: SkyModel, width: Int, height: Int, fovDeg: Double = 90, pitchDeg: Double = 8,
                              yawDeg: Double = 0, exposure: Double? = nil) -> [UInt8] {
        let ex = exposure ?? autoExposure(m)
        let sunAz = atan2(m.sunDirection.z, m.sunDirection.x)
        let yaw = sunAz + yawDeg * .pi / 180, pitch = pitchDeg * .pi / 180
        let fwd = V3(cos(pitch) * cos(yaw), sin(pitch), cos(pitch) * sin(yaw))
        let right = V3(-sin(yaw), 0, cos(yaw))
        let up = V3(fwd.y * right.z - fwd.z * right.y, fwd.z * right.x - fwd.x * right.z, fwd.x * right.y - fwd.y * right.x) * -1
        let tanH = tan(fovDeg * .pi / 360), tanV = tanH * Double(height) / Double(width)
        let sunColor = m.sunTransmittance
        let sunUp = max(0, m.sunDirection.y)
        // Ambient sky irradiance on a horizontal surface, from the sky-view LUT (cosine weighted).
        var ambient = V3.zero
        let samples = 64
        for i in 0..<samples {
            let ct = (Double(i % 8) + 0.5) / 8, az = Double(i / 8) / 8 * 2 * .pi
            let st = (1 - ct * ct).squareRoot()
            ambient += m.radiance(V3(st * cos(az), ct, st * sin(az)), includeSun: false) * ct
        }
        ambient *= 2 * .pi / Double(samples)
        let skyAmbient = ambient
        let albedo = V3(0.16, 0.20, 0.11)
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let rowsPerChunk = 8
        let chunks = (height + rowsPerChunk - 1) / rowsPerChunk
        out.withUnsafeMutableBufferPointer { buf in
            let base = UnsafeSendablePointer(buf.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                for y in (c * rowsPerChunk)..<min(height, (c + 1) * rowsPerChunk) {
                    for x in 0..<width {
                        let sx = (2 * (Double(x) + 0.5) / Double(width) - 1) * tanH
                        let sy = (1 - 2 * (Double(y) + 0.5) / Double(height)) * tanV
                        var d = fwd + right * sx + up * sy
                        d /= (d * d).sum().squareRoot()
                        var L: V3
                        if d.y >= -0.0005 {
                            L = m.radiance(d)
                        } else {
                            // Ground at the viewer's height below: distance to the plane.
                            let dist = min(400, m.viewHeightKm / -d.y)
                            let lit = albedo / .pi * (sunColor * sunUp + skyAmbient)
                            let (inscatter, t) = m.aerialPerspective(d, distanceKm: dist, steps: 10)
                            L = lit * t + inscatter
                        }
                        let i = 3 * (y * width + x)
                        for k in 0..<3 {
                            let v = pow(aces(L[k] * ex), 1 / 2.2)
                            base.p[i + k] = UInt8((v * 255).rounded())
                        }
                    }
                }
            }
        }
        return out
    }
}

struct UnsafeSendablePointer: @unchecked Sendable {
    let p: UnsafeMutablePointer<UInt8>
    init(_ p: UnsafeMutablePointer<UInt8>) { self.p = p }
}
