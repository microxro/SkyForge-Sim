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
