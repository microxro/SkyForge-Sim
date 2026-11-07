import Testing
@testable import SFWorldGen

@Suite struct WorldGenVersionTests {
    @Test func versionPositive() { #expect(SFWorldGenInfo.worldgenVersion >= 1) }
}
