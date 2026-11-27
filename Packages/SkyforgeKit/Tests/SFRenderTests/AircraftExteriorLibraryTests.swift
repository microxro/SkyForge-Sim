// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFRender

/// Guards the round-5 exterior MSL that WorldRenderer splices into the world library. The MSL itself is only
/// syntax-checked (tools/msl_check); these tests catch the two integration mistakes that would break the build:
/// a stray #include in the middle of the library, and a helper the world shader calls going missing.
@Suite struct AircraftExteriorLibraryTests {
    @Test func spliceSourceHasNoIncludeOrNamespaceLine() {
        let s = AircraftExteriorShaders.source
        #expect(!s.contains("#include"))
        #expect(!s.contains("using namespace"))
    }

    @Test func worldShaderHelpersAreDefined() {
        let s = AircraftExteriorShaders.source
        for helper in ["ax_rivet(", "ax_tilt(", "ax_dirt(", "ax_clearcoat("] {
            // A definition, not just a mention: the helper's name preceded by its return type.
            #expect(s.contains(" " + helper), "missing \(helper)")
        }
    }
}
