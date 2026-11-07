import Testing
@testable import SFFlightModel

@Suite struct FlightModelModuleTests {
    @Test func moduleVersionPresent() { #expect(!SFFlightModelInfo.moduleVersion.isEmpty) }
}
