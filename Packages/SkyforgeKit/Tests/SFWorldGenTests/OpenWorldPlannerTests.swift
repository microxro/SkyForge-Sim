import Foundation
import Testing
import SFMath
@testable import SFWorldGen

/// Gentle hills with a sea to the east and a lake to the west. Heights are finite everywhere.
private struct HillTerrain: OpenWorldTerrain {
    func height(_ x: Double, _ y: Double) -> Double {
        let a: Double = 4 * sin(x / 1_700)
        let b: Double = 3 * cos(y / 1_100)
        let c: Double = 0.8 * sin((x + y) / 600)
        return a + b + c
    }
    func isWater(_ x: Double, _ y: Double) -> Bool {
        x > 21_000 || (x < -20_000 && y > 8_000)
    }
}

@Suite struct OpenWorldPlannerTests {
    private let planner = OpenWorldPlanner(seed: 7, terrain: HillTerrain(), extent: 16_000, cellSize: 6_000)

    @Test func tiersOrdered() {
        #expect(SettlementTier.hamlet < .village)
        #expect(SettlementTier.city < .metropolis)
        #expect(SettlementTier.metropolis.radius > SettlementTier.city.radius)
    }

    @Test func sitesDeterministicAndDry() {
        let a = planner.sites(), b = planner.sites()
        #expect(a == b)
        #expect(!a.isEmpty)
        for s in a { #expect(!HillTerrain().isWater(s.centre.x, s.centre.y)) }
    }

    @Test func planDeterministicAndSeedSensitive() {
        let site = planner.sites()[0]
        #expect(planner.plan(site).contentHash == planner.plan(site).contentHash)
        let other = OpenWorldPlanner(seed: 8, terrain: HillTerrain(), extent: 16_000, cellSize: 6_000)
        let plansA = planner.makePlan().settlements.map(\.contentHash)
        let plansB = other.makePlan().settlements.map(\.contentHash)
        #expect(plansA != plansB)
    }

    @Test func lotsStayInsideRadiusAndDry() {
        for site in planner.sites() {
            let s = planner.plan(site)
            for lot in s.lots {
                #expect(owDistance(lot.centre, site.centre) <= site.tier.radius * 1.05)
                #expect(!HillTerrain().isWater(lot.centre.x, lot.centre.y))
                #expect(lot.wallHeight.isFinite && lot.wallHeight > 0)
            }
        }
    }

    @Test func lotsDoNotOverlap() {
        for site in planner.sites() {
            let lots = planner.plan(site).lots
            guard lots.count <= 300 else { continue }
            for i in lots.indices {
                for j in lots.indices where j > i {
                    let ri = owDistance(lots[i].halfSize, .zero), rj = owDistance(lots[j].halfSize, .zero)
                    #expect(owDistance(lots[i].centre, lots[j].centre) >= ri + rj)
                }
            }
        }
    }

    @Test func proceduralAirportsAreFlatAndDry() {
        let terrain = HillTerrain()
        for s in planner.makePlan().settlements {
            for a in planner.airports(for: s) {
                for r in a.runways {
                    #expect(!terrain.isWater(r.threshold.x, r.threshold.y))
                    #expect(r.lowDesignator.count == 2 && r.highDesignator.count == 2)
                }
                #expect(a.padElevation.isFinite)
                #expect(a.buildings.allSatisfy { $0.ground == a.padElevation })
            }
        }
    }

    @Test func haldenAnchorsKeepPositionsAndElevations() {
        let layouts = HaldenReachAnchors.airports.map { planner.layout(for: $0) }
        #expect(layouts.count == 10)
        for (anchor, layout) in zip(HaldenReachAnchors.airports, layouts) {
            #expect(layout.centre == anchor.centre)
            #expect(layout.padElevation == anchor.elevation)
            #expect(layout.id == anchor.id)
        }
        let hub = layouts.first { $0.id == "HRCI" }
        #expect(hub?.runways.first.map { $0.length } == 3_600)
        #expect(layouts.first { $0.id == "HRYS" }?.waterLane != nil)
    }

    @Test func anchoredCitiesKeepNamesAndCentres() {
        let plan = planner.makePlan(cities: HaldenReachAnchors.cities)
        for city in HaldenReachAnchors.cities {
            let found = plan.settlements.first { $0.name == city.name }
            #expect(found != nil)
            #expect(found?.site.centre == city.centre)
        }
        // Procedural sites stay clear of the anchored cities.
        for s in plan.settlements where !HaldenReachAnchors.cities.contains(where: { $0.name == s.name }) {
            for city in HaldenReachAnchors.cities {
                #expect(owDistance(s.site.centre, city.centre) >= 2_500)
            }
        }
    }

    @Test func namesNonEmpty() {
        for seed in UInt64(1)...50 { #expect(!OpenWorldNames.name(seed: seed).isEmpty) }
    }
}

private func owDistance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let d = a - b
    return (d.x * d.x + d.y * d.y).squareRoot()
}
