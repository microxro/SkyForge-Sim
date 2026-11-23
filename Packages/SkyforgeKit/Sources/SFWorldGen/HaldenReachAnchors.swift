// SKYFORGE — Apache-2.0
// Fixed cities and airports of the Halden Reach original world, copied from docs/worlds/halden-reach/world.json.
// Positions are kilometres in the world's south-west origin frame, converted to metres here. The planner never moves them.
import Foundation
import SFMath

public enum HaldenReachAnchors {
    private static func km(_ x: Double, _ y: Double) -> SIMD2<Double> { SIMD2<Double>(x * 1_000, y * 1_000) }

    public static let cities: [OpenWorldPlanner.AnchorCity] = [
        .init(name: "Caldera", centre: km(96, 46), tier: .metropolis, population: 320_000),
        .init(name: "Port Serrin", centre: km(118, 36), tier: .city, population: 110_000),
        .init(name: "Northgate", centre: km(70, 84), tier: .city, population: 60_000),
        .init(name: "Brightwater", centre: km(34, 66), tier: .city, population: 45_000),
        .init(name: "Ashwold", centre: km(28, 24), tier: .town, population: 12_000),
        .init(name: "Millbrook", centre: km(84, 30), tier: .town, population: 8_000),
        .init(name: "Tessel Falls", centre: km(100, 20), tier: .town, population: 6_000),
        .init(name: "Greyhaven", centre: km(54, 72), tier: .town, population: 4_000),
        .init(name: "Kestrel Cross", centre: km(116, 62), tier: .town, population: 3_000),
        .init(name: "Saltmarsh", centre: km(22, 42), tier: .village, population: 2_000),
    ]

    public static let airports: [AnchorAirport] = [
        AnchorAirport(id: "HRCI", name: "Caldera International", centre: km(92, 42), elevation: 40, runwayLength: 3_600, kind: .hub, paved: true),
        AnchorAirport(id: "HRPS", name: "Port Serrin Regional", centre: km(116, 40), elevation: 15, runwayLength: 1_800, kind: .regional, paved: true),
        AnchorAirport(id: "HRNG", name: "Northgate Field", centre: km(72, 80), elevation: 210, runwayLength: 1_400, kind: .regional, paved: true),
        AnchorAirport(id: "HRBW", name: "Brightwater Strip", centre: km(30, 62), elevation: 60, runwayLength: 900, kind: .generalAviation, paved: true),
        AnchorAirport(id: "HRKX", name: "Kestrel Cross Field", centre: km(114, 66), elevation: 90, runwayLength: 1_000, kind: .generalAviation, paved: false),
        AnchorAirport(id: "HRAH", name: "Ashwold Hangar Strip", centre: km(26, 20), elevation: 480, runwayLength: 700, kind: .bushStrip, paved: false),
        AnchorAirport(id: "HRTS", name: "Tessel Strip", centre: km(108, 16), elevation: 35, runwayLength: 500, kind: .bushStrip, paved: false),
        AnchorAirport(id: "HRKT", name: "Kestrel Tor", centre: km(50, 56), elevation: 1_120, runwayLength: 620, kind: .bushStrip, paved: false),
        AnchorAirport(id: "HRAR", name: "Ardent Rest", centre: km(64, 54), elevation: 1_900, runwayLength: 800, kind: .mountainStrip, paved: false),
        AnchorAirport(id: "HRYS", name: "Lake Ysolde Water Base", centre: km(58, 36), elevation: 180, runwayLength: 1_200, kind: .seaplaneBase, paved: false),
    ]
}
