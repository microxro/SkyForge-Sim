import Testing
import Foundation
@testable import SFPreview

@Suite struct PNGEncoderTests {
    @Test func crcKnownValue() {
        #expect(PNGEncoder.crc32(Array("123456789".utf8)) ^ 0xFFFF_FFFF == 0xCBF4_3926)
    }
    @Test func adlerKnownValue() {
        #expect(PNGEncoder.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
    }
    @Test func headerAndSize() {
        let d = PNGEncoder.encodeRGB(width: 4, height: 3, rgb: [UInt8](repeating: 128, count: 36))
        #expect(Array(d.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(d.count > 50)
    }
}

import SFTerrainCore

@Suite struct PNGRoundTripTests {
    /// Encoded frames decode back exactly (stored blocks on Linux; Sub filter + DEFLATE on Apple platforms).
    @Test func encodeDecodeRoundTrip() throws {
        let w = 97, h = 31
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<rgb.count { rgb[i] = UInt8((i * 7 + (i / 291) * 13) & 0xFF) }
        let png = PNGEncoder.encodeRGB(width: w, height: h, rgb: rgb)
        let d = try PNGDecoder.decode([UInt8](png))
        #expect(d.width == w && d.height == h && d.channels == 3)
        #expect(d.pixels == rgb)
        #if canImport(Darwin)
        var flat = [UInt8](repeating: 120, count: 640 * 360 * 3)
        flat[5] = 3
        #expect(PNGEncoder.encodeRGB(width: 640, height: 360, rgb: flat).count < 20_000, "compressed on Apple platforms")
        #endif
    }
}
