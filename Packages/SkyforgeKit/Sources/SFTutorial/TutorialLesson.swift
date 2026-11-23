// SKYFORGE — Apache-2.0
// First-flight lessons for brand-new players. Pure Swift, Linux-testable.
// The lessons read a plain snapshot of the aircraft, so any UI (SwiftUI, Metal) can draw the prompts
// and the sim can feed the checks without this module knowing about the flight model.
import Foundation

/// The aircraft state the lessons check. Units match the instruments: knots, feet, degrees, fpm.
public struct TutorialSnapshot: Sendable, Equatable {
    public var indicatedAirspeedKt: Double
    public var groundSpeedKt: Double
    public var altitudeAGLFt: Double
    public var verticalSpeedFpm: Double
    public var pitchDeg: Double
    public var rollDeg: Double
    public var headingDeg: Double
    /// Heading of the runway the player is using (degrees true).
    public var runwayHeadingDeg: Double
    public var onGround: Bool
    /// Throttle position 0…1.
    public var throttle: Double
    /// Flap position 0…1.
    public var flapsFraction: Double

    public init(indicatedAirspeedKt: Double = 0, groundSpeedKt: Double = 0, altitudeAGLFt: Double = 0,
                verticalSpeedFpm: Double = 0, pitchDeg: Double = 0, rollDeg: Double = 0, headingDeg: Double = 0,
                runwayHeadingDeg: Double = 0, onGround: Bool = true, throttle: Double = 0, flapsFraction: Double = 0) {
        self.indicatedAirspeedKt = indicatedAirspeedKt
        self.groundSpeedKt = groundSpeedKt
        self.altitudeAGLFt = altitudeAGLFt
        self.verticalSpeedFpm = verticalSpeedFpm
        self.pitchDeg = pitchDeg
        self.rollDeg = rollDeg
        self.headingDeg = headingDeg
        self.runwayHeadingDeg = runwayHeadingDeg
        self.onGround = onGround
        self.throttle = throttle
        self.flapsFraction = flapsFraction
    }

    /// True when every number is finite. Bad frames are ignored rather than advancing a lesson.
    public var isFinite: Bool {
        [indicatedAirspeedKt, groundSpeedKt, altitudeAGLFt, verticalSpeedFpm, pitchDeg, rollDeg,
         headingDeg, runwayHeadingDeg, throttle, flapsFraction].allSatisfy { $0.isFinite }
    }
}

/// Per-lesson memory that survives frames, such as how far the nose has swung since the lesson started.
public struct TutorialProgress: Sendable, Equatable {
    /// Degrees of heading change since the lesson started (absolute, so left and right both count).
    public var headingTurned: Double = 0
    /// Set once the aircraft has left the ground during the current lesson.
    public var sawAirborne = false
    public init() {}
}

/// A recovery message shown when the player drifts out of the safe envelope. Gentle by design:
/// it explains, and it can send the player back to an earlier lesson.
public struct TutorialRecovery: Sendable, Equatable {
    public let text: String
    public let returnTo: TutorialLesson?
}

public enum TutorialLesson: String, CaseIterable, Sendable, Identifiable {
    case controls, instruments, throttle, taxi, takeoff, climb, turn, trim, pattern, approach, landing

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .controls: "Controls"
        case .instruments: "Read the instruments"
        case .throttle: "Power"
        case .taxi: "Taxi"
        case .takeoff: "Takeoff"
        case .climb: "Climb"
        case .turn: "Turn"
        case .trim: "Trim"
        case .pattern: "Downwind"
        case .approach: "Descent and flaps"
        case .landing: "Landing"
        }
    }

    /// What the player should do now. Written as short sentences for a phone screen.
    public var prompt: String {
        switch self {
        case .controls:
            "Touch: drag the yoke to steer, slide the throttle to add power. Keyboard: W and S move the nose down and up, A and D roll, Q and E yaw, F lowers flaps. Tap Got it when you are ready."
        case .instruments:
            "Airspeed is on the left, altitude on the right, heading along the bottom. Tap Got it once you have found all three."
        case .throttle:
            "Add power slowly. Watch the airspeed build while you roll on the runway."
        case .taxi:
            "Steer along the taxiway with the yoke. Keep the speed at a walking pace and turn at least 20 degrees."
        case .takeoff:
            "Line up on the centre of the runway, push the throttle to nearly full, and ease the nose up when the speed is near 60 knots."
        case .climb:
            "Hold a gentle nose-up attitude and climb at least 300 feet per minute until you reach about 500 feet."
        case .turn:
            "Roll into a turn of about 30 degrees, then roll wings level."
        case .trim:
            "Hold 90 knots and fly level for a few seconds. Trim lets the plane hold its attitude so you can take your hands off the controls."
        case .pattern:
            "Turn to face the runway's reverse direction and fly the downwind leg about 1,000 feet up."
        case .approach:
            "Pull the throttle back, press F to lower flaps halfway, and descend at 65 to 80 knots."
        case .landing:
            "Flare just above the runway, hold the nose up, and let the main wheels touch first."
        }
    }

    /// Escalating hints. The engine shows the first one after a short pause and the next after a longer one.
    public var hints: [String] {
        switch self {
        case .controls: ["Nothing to fly yet. Tap Got it to continue."]
        case .instruments: ["Look at the three gauges on the panel, then tap Got it."]
        case .throttle: ["Slide the throttle up a little at a time.", "Airspeed should climb past 15 knots on the runway."]
        case .taxi: ["Turn the yoke gently left or right.", "Slow down if the runway seems to blur past."]
        case .takeoff: ["Full power, keep the wings level with small yoke moves.", "Ease back on the yoke near 60 knots."]
        case .climb: ["Nose up a little, not too much.", "Watch the vertical speed. It should read above 300."]
        case .turn: ["Roll in one direction with the yoke, then roll back.", "A standard rate turn is about 3 degrees a second."]
        case .trim: ["Make small pitch corrections, then let go.", "Keep the speed between 80 and 100 knots."]
        case .pattern: ["Turn about 180 degrees from the runway heading.", "Stay at roughly 1,000 feet above the runway."]
        case .approach: ["Reduce power, then press F to add flaps.", "Aim for a descent of a few hundred feet per minute."]
        case .landing: ["Hold the nose slightly up as you cross the threshold.", "Keep the wings level until the wheels touch."]
        }
    }

    /// Seconds the check has to hold before the lesson is done. Confirm-only lessons ignore this.
    public var holdSeconds: Double {
        switch self {
        case .throttle, .taxi, .takeoff, .landing, .controls, .instruments: 0
        case .turn: 2
        case .climb, .trim: 5
        case .pattern: 4
        case .approach: 3
        }
    }

    /// Lessons the player finishes by tapping, not by flying.
    public var requiresConfirm: Bool {
        self == .controls || self == .instruments
    }

    /// True when the aircraft is currently doing what the lesson asks.
    public func isMet(_ s: TutorialSnapshot, _ p: TutorialProgress) -> Bool {
        let airborne = !s.onGround
        switch self {
        case .controls, .instruments:
            return false
        case .throttle:
            return s.throttle >= 0.3 && s.groundSpeedKt >= 10
        case .taxi:
            return s.onGround && (3...25).contains(s.groundSpeedKt) && p.headingTurned >= 20
        case .takeoff:
            return airborne && s.altitudeAGLFt >= 20
        case .climb:
            return airborne && (5...15).contains(s.pitchDeg) && s.verticalSpeedFpm >= 300 && s.altitudeAGLFt >= 300
        case .turn:
            return airborne && p.headingTurned >= 30 && abs(s.rollDeg) <= 5
        case .trim:
            return airborne && (80...100).contains(s.indicatedAirspeedKt) && abs(s.verticalSpeedFpm) < 200
        case .pattern:
            let reciprocal = Self.normalise(s.runwayHeadingDeg + 180)
            return airborne && s.altitudeAGLFt >= 700 && Self.angularDistance(s.headingDeg, reciprocal) <= 20
        case .approach:
            return airborne && s.flapsFraction >= 0.5 && (60...85).contains(s.indicatedAirspeedKt)
                && (-1000...(-200)).contains(s.verticalSpeedFpm)
        case .landing:
            return s.onGround && p.sawAirborne && s.groundSpeedKt < 30
        }
    }

    /// Something the player should hear about right now, or nil when all is well.
    public func recovery(_ s: TutorialSnapshot) -> TutorialRecovery? {
        switch self {
        case .taxi:
            if s.onGround && s.groundSpeedKt > 30 {
                return TutorialRecovery(text: "That is quicker than taxi speed. Ease the throttle back.", returnTo: nil)
            }
        case .takeoff:
            if s.onGround && s.groundSpeedKt < 2 && s.throttle < 0.5 {
                return TutorialRecovery(text: "Power first. Push the throttle up to start rolling.", returnTo: nil)
            }
        case .climb:
            if !s.onGround && s.indicatedAirspeedKt < 60 {
                return TutorialRecovery(text: "Speed is dropping. Lower the nose a little.", returnTo: nil)
            }
            if !s.onGround && s.indicatedAirspeedKt > 130 {
                return TutorialRecovery(text: "Getting fast. Raise the nose a little.", returnTo: nil)
            }
        case .turn:
            if !s.onGround && abs(s.rollDeg) > 50 {
                return TutorialRecovery(text: "That is too steep. Roll back toward level.", returnTo: nil)
            }
        case .approach:
            if !s.onGround && s.indicatedAirspeedKt > 110 {
                return TutorialRecovery(text: "Too fast for the approach. Reduce power and add flaps.", returnTo: nil)
            }
        case .landing:
            if !s.onGround && s.altitudeAGLFt < 150 && s.verticalSpeedFpm < -900 {
                return TutorialRecovery(text: "Sinking too fast. Go around: full power, nose up gently.", returnTo: .approach)
            }
        default:
            break
        }
        return nil
    }

    static func normalise(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// Smallest absolute difference between two headings, in degrees (0…180).
    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        var d = abs(normalise(a) - normalise(b))
        if d > 180 { d = 360 - d }
        return d
    }

    /// Signed heading change from `from` to `to`, in degrees (−180…180).
    static func headingDelta(from: Double, to: Double) -> Double {
        var d = normalise(to) - normalise(from)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
