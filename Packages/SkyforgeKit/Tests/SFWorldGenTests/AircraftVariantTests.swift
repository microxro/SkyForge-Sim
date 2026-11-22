// SKYFORGE — Apache-2.0
import Testing
import SFMath
@testable import SFWorldGen

@Suite struct AircraftVariantTests {
    struct Expected {
        var gearZ: Double          // wheel contact height below the CG in the flight model
        var span: Double
        var length: ClosedRange<Double>
        var prop: Bool
    }
    static func expected(_ id: String) -> Expected {
        switch id {
        case "org.skyforge.sfc": return Expected(gearZ: 1.30, span: 10.2, length: 8.0...9.6, prop: true)
        case "org.skyforge.sfa": return Expected(gearZ: 1.15, span: 9.0, length: 6.0...7.4, prop: true)
        case "org.skyforge.sft1": return Expected(gearZ: 1.35, span: 9.4, length: 11.5...13.5, prop: false)
        default: return Expected(gearZ: 1.70, span: 9.4, length: 14.5...16.0, prop: false)   // org.skyforge.sff1
        }
    }

    @Test(arguments: AircraftVariants.ids)
    func meshIsFiniteWithUnitNormalsAndMatchingDimensions(id: String) throws {
        let plane = (id: id, gearZ: Self.expected(id).gearZ, span: Self.expected(id).span, length: Self.expected(id).length, prop: Self.expected(id).prop)
        let built = try #require(AircraftVariants.build(id: plane.id))
        let tris = built.triangles
        #expect(tris.count > 600, "\(plane.id): \(tris.count) triangles")
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity, maxZ = -Double.infinity
        for t in tris {
            for p in [t.a, t.b, t.c] {
                #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite)
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y); maxZ = max(maxZ, p.z)
            }
            for n in [t.na, t.nb, t.nc] {
                #expect(n.x.isFinite && n.y.isFinite && n.z.isFinite)
                #expect(abs((n * n).sum().squareRoot() - 1) < 1e-6, "\(plane.id): non-unit normal \(n)")
            }
        }
        #expect(abs((maxY - minY) - plane.span) < 0.15, "\(plane.id) span \(maxY - minY)")
        #expect(plane.length.contains(maxX - minX), "\(plane.id) length \(maxX - minX)")
        // Wheels touch down at the flight model's gear height, nothing hangs lower, and the airframe is left-right symmetric.
        #expect(abs(maxZ - plane.gearZ) < 0.05, "\(plane.id) lowest point \(maxZ)")
        #expect(abs(maxY + minY) < 0.05)
        #expect(AircraftVariants.gearZ(for: plane.id) == plane.gearZ)
        // Only the propeller types carry a prop disc; every type has a glazed canopy and tyres.
        #expect(tris.contains { $0.part == .prop } == plane.prop)
        #expect(tris.contains { $0.part == .glass } && tris.contains { $0.part == .tyre } && tris.contains { $0.part == .metal })
        #expect(built.style.hasPropeller == plane.prop)
    }

    /// Wheels sit under the CG's gear legs (nose ahead of it, mains behind), at the catalog's x positions.
    @Test func noseGearAheadOfMainGear() throws {
        for id in AircraftVariants.ids {
            let plane = (id: id, gearZ: Self.expected(id).gearZ)
            let tris = try #require(AircraftVariants.build(id: plane.id)).triangles
            let tyres = tris.filter { $0.part == .tyre && abs($0.a.z - plane.gearZ) < 1.0 }
            let nose = tyres.filter { abs($0.a.y) < 0.2 }.map { $0.a.x }
            let main = tyres.filter { abs($0.a.y) > 0.5 }.map { $0.a.x }
            #expect(!nose.isEmpty && !main.isEmpty, "\(plane.id)")
            if let n = nose.max(), let m = main.max() { #expect(n > m + 0.5, "\(plane.id): nose \(n) main \(m)") }
        }
    }

    /// The SF-1 and unknown ids are not variants (callers fall back to the SF-1 mesh).
    @Test func unknownIdsFallBack() {
        #expect(AircraftVariants.build(id: "org.skyforge.sf1") == nil)
        #expect(AircraftVariants.build(id: "nonsense") == nil)
        #expect(AircraftVariants.ids.count == 4)
    }
}
