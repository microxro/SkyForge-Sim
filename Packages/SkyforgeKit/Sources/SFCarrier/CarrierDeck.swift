// SKYFORGE — Apache-2.0
// Carrier deck geometry: a moving ship, the wind over its deck and the arresting-wire layout.
// Pure Swift and deterministic. World axes are NED (x north, y east, z down), as in SFGameplay.
// Deck-local axes used by the launch and trap models: distances are metres measured aft of the ramp
// (positive aft), and lateral offsets are metres to starboard.
// Dimensions are approximate and for gameplay, not a specific ship.
import Foundation

@inline(__always)
func carrierDot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }

public struct ArrestingWire: Sendable, Codable, Equatable {
    public var number: Int             // 1 is the aft-most wire, as on US carriers
    public var aftDistance: Double     // m aft of the ramp

    public init(number: Int, aftDistance: Double) {
        self.number = number
        self.aftDistance = aftDistance
    }
}

public struct CarrierDeck: Sendable, Codable, Equatable {
    public var position: SIMD3<Double>     // NED position of the ramp, m
    public var heading: Double             // rad from north, clockwise
    public var speed: Double               // m/s through the water
    public var length: Double              // m, ramp to stern
    public var wires: [ArrestingWire]      // sorted by aftDistance, ascending (forward to aft)

    public init(position: SIMD3<Double>, heading: Double, speed: Double, length: Double, wires: [ArrestingWire]) {
        self.position = position
        self.heading = heading
        self.speed = speed
        self.length = length
        self.wires = wires.sorted { $0.aftDistance < $1.aftDistance }
    }

    /// Four wires, 15 m apart, with wire 3 as the target wire. Wire 1 is the aft-most.
    public static func standard(position: SIMD3<Double> = .zero, heading: Double = 0, speed: Double = 0) -> CarrierDeck {
        CarrierDeck(position: position, heading: heading, speed: speed, length: 230,
                    wires: [ArrestingWire(number: 4, aftDistance: 110),
                            ArrestingWire(number: 3, aftDistance: 125),
                            ArrestingWire(number: 2, aftDistance: 140),
                            ArrestingWire(number: 1, aftDistance: 155)])
    }

    /// The wire the crew wants the hook on.
    public static let targetWireNumber = 3

    public var forward: SIMD3<Double> { SIMD3(cos(heading), sin(heading), 0) }
    public var starboard: SIMD3<Double> { SIMD3(-sin(heading), cos(heading), 0) }

    /// Ship velocity over the ground, NED, m/s.
    public var velocity: SIMD3<Double> { forward * speed }

    /// Air velocity relative to the deck, NED. `trueWind` is the air mass velocity, NED (where the air moves to).
    public func relativeAir(trueWind: SIMD3<Double>) -> SIMD3<Double> { trueWind - velocity }

    /// Headwind over the deck in m/s. Positive means air reaches the deck from the bow. A calm sea
    /// at 15 m/s gives a 15 m/s headwind, and a 10 m/s true wind from the north on the same ship
    /// adds to that, giving 25 m/s.
    public func headwind(trueWind: SIMD3<Double>) -> Double {
        -carrierDot(relativeAir(trueWind: trueWind), forward)
    }

    /// Crosswind over the deck in m/s. Positive means air moves to starboard (the wind blows from port).
    public func crosswind(trueWind: SIMD3<Double>) -> Double {
        carrierDot(relativeAir(trueWind: trueWind), starboard)
    }

    /// NED position of a deck point. `aft` is metres aft of the ramp and `lateral` is metres to starboard.
    public func deckPoint(aft: Double, lateral: Double = 0) -> SIMD3<Double> {
        position - forward * aft + starboard * lateral
    }
}
