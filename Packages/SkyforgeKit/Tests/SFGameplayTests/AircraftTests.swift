import Testing
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel
@testable import SFGameplay

@Suite struct AircraftTests {
    @Test func idsAreUniqueAndLookupWorks() {
        let ids = AircraftCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for a in AircraftCatalog.all { #expect(AircraftCatalog.spec(id: a.id) == a) }
        #expect(AircraftCatalog.military.allSatisfy { $0.flyByWire && !$0.armament.isEmpty })
        #expect(AircraftCatalog.civil.allSatisfy { $0.armament.isEmpty })
    }

    @Test func speedsAreOrderedAndTrimConverges() {
        for a in AircraftCatalog.all {
            let vs = a.stallSpeed(flaps: 1)
            #expect(a.approachSpeed >= 1.25 * vs, "\(a.name) approach \(a.approachSpeed) vs stall \(vs)")
            #expect(a.cruiseSpeed > a.approachSpeed && a.limits.vne > a.cruiseSpeed)
            for (v, flaps, alt) in [(a.cruiseSpeed, 0.0, 1_000.0), (a.approachSpeed, a.approachFlaps, 200.0)] {
                let t = a.model.trimLevel(trueAirspeed: v, altitude: alt, flaps: flaps, gear: v < a.approachSpeed * 1.35 ? 1 : 0)
                #expect(t.converged, "\(a.name) trim at \(v) m/s")
                #expect(t.inputs.throttle >= 0 && t.inputs.throttle <= 1, "\(a.name) throttle \(t.inputs.throttle)")
                #expect(abs(t.inputs.elevator) < 0.8, "\(a.name) elevator \(t.inputs.elevator)")
            }
        }
    }

    @Test func jetStaticThrustIsInTheDesignBand() {
        let a = AircraftCatalog.sfT1Jet
        var s = AircraftState(positionNED: SIMD3(0, 0, -1_000), velocityBody: .zero, attitude: .identity, bodyRates: .zero)
        s.time = 0
        let out = a.model.outputs(s, inputs: ControlInputs(throttle: 1), environment: FlightEnvironment())
        let sigma = ISA.state(geometricAltitude: 1_000).density / ISA.seaLevelDensity
        #expect(abs(out.thrust - 26_000 * pow(sigma, 1.1)) < 1_500)
    }

    @Test func loadFactorIsOneInTrim() {
        for a in AircraftCatalog.all {
            let t = a.model.trimLevel(trueAirspeed: a.cruiseSpeed, altitude: 1_000)
            let o = a.model.outputs(t.state, inputs: t.inputs, environment: FlightEnvironment())
            let nz = EnvelopeMath.loadFactor(state: t.state, outputs: o, config: a.config)
            #expect(abs(nz - 1) < 0.03, "\(a.name) nz \(nz)")
        }
    }

    @Test func controlLawRestrictsStickAtSpeedOnly() {
        let f = AircraftCatalog.sfF1Fighter
        let law = FlightControlLaw(limits: f.limits, config: f.config)
        let fast = law.elevatorRange(qbar: 0.5 * 1.1 * 250 * 250)
        let slow = law.elevatorRange(qbar: 100)
        #expect(fast.max < 0.5 && fast.max > 0)
        #expect(slow.max > 0.3 && slow.max <= 1)
        #expect(fast.min < 0 && fast.min >= -1)
        var pilot = ControlInputs(); pilot.elevator = 1
        #expect(law.apply(pilot, qbar: 0.5 * 1.1 * 250 * 250, nz: 1).elevator < 0.5)
        // Residual feedback pulls the stick back when load factor is over the limit.
        #expect(law.apply(pilot, qbar: 100, nz: 12).elevator < law.apply(pilot, qbar: 100, nz: 1).elevator)
    }

    @Test func monitorRaisesWarningsAndFailsAirframe() {
        let lim = AircraftCatalog.sfF1Fighter.limits
        var m = EnvelopeMonitor(limits: lim)
        m.update(nz: 10, trueAirspeed: 100, mach: 0.3, flaps: 0, stalled: false, onGround: false, heightAGL: 3_000, sinkRate: 0, dt: 0.1)
        #expect(m.warnings == [.overG] && m.overstressSeconds > 0 && !m.structuralFailure)
        m.update(nz: 1, trueAirspeed: 100, mach: 1.7, flaps: 0, stalled: false, onGround: false, heightAGL: 100, sinkRate: 60, dt: 0.1)
        #expect(m.warnings == [.overMach, .terrain])
        // One spike does not break the airframe; neither does a hard landing on the gear.
        m.update(nz: 14, trueAirspeed: 100, mach: 0.3, flaps: 0, stalled: false, onGround: false, heightAGL: 3_000, sinkRate: 0, dt: 0.1)
        m.update(nz: 1, trueAirspeed: 100, mach: 0.3, flaps: 0, stalled: false, onGround: false, heightAGL: 3_000, sinkRate: 0, dt: 0.1)
        for _ in 0..<10 { m.update(nz: 20, trueAirspeed: 60, mach: 0.2, flaps: 1, stalled: false, onGround: true, heightAGL: 2, sinkRate: 0, dt: 0.1) }
        #expect(!m.structuralFailure)
        // Held past the limit in the air, it fails.
        for _ in 0..<3 { m.update(nz: 14, trueAirspeed: 100, mach: 0.3, flaps: 0, stalled: false, onGround: false, heightAGL: 3_000, sinkRate: 0, dt: 0.1) }
        #expect(m.structuralFailure)
    }
}
