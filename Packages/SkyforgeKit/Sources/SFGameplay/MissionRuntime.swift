// SKYFORGE — Apache-2.0
// Mission state machine: objectives run in order against a stream of flight samples; the runtime
// scores them and decides success or failure. Pure and deterministic, so it replays from a log.
import Foundation
import SFMath

public struct FlightSample: Sendable, Equatable {
    public var time: Double
    public var positionNED: SIMD3<Double>
    public var velocityNED: SIMD3<Double>
    public var heightAGL: Double            // wheels above the ground
    public var onGround: Bool
    public var crashed: Bool
    public var crashReason: String?

    public init(time: Double, positionNED: SIMD3<Double>, velocityNED: SIMD3<Double>, heightAGL: Double,
                onGround: Bool, crashed: Bool = false, crashReason: String? = nil) {
        self.time = time; self.positionNED = positionNED; self.velocityNED = velocityNED
        self.heightAGL = heightAGL; self.onGround = onGround; self.crashed = crashed; self.crashReason = crashReason
    }

    public var groundSpeed: Double { (velocityNED.x * velocityNED.x + velocityNED.y * velocityNED.y).squareRoot() }
    /// Descent rate (m/s, positive when descending).
    public var sinkRate: Double { velocityNED.z }
}

public enum MissionStatus: Sendable, Equatable {
    case inProgress
    case succeeded
    case failed(String)
}

public enum MissionEvent: Sendable, Equatable {
    case objectiveCompleted(id: String)
    case succeeded
    case failed(reason: String)
}

public struct MissionRuntime: Sendable {
    public let mission: MissionDefinition
    public let frame: RunwayFrame
    public let aircraftID: String
    public private(set) var status: MissionStatus = .inProgress
    public private(set) var objectiveIndex = 0
    /// 0...1 progress of the current objective for the HUD.
    public private(set) var progress = 0.0
    public private(set) var elapsed = 0.0
    public private(set) var result: MissionResult?
    /// Points earned per completed objective id.
    public private(set) var earned: [String: Int] = [:]
    /// Hostile aircraft destroyed so far (reported by the session; copied into the result).
    public private(set) var kills = 0
    /// Latest combat tally handed to `update`; copied into the result at finish.
    public private(set) var combat = CombatTally()

    // Per-objective accumulators, reset when an objective starts.
    private var started = false
    private var startTime = 0.0
    private var objectiveStart = 0.0
    private var hold = 0.0
    private var routeIndex = 0
    // Loop tracking: unwrapped angle of the velocity vector in the vertical plane through the start heading.
    private var loopRef: SIMD2<Double>?
    private var loopPrev: Double?
    private var loopAngle = 0.0
    private var belowTime = 0.0
    private var outOfBandTime = 0.0
    private var errorSum = 0.0
    private var errorSamples = 0
    private var lostTime = 0.0
    /// Radar lock reported for the current update step only.
    private var currentLockID: String?
    private var initialDistance = 0.0
    // Landing
    private var touchedDown = false
    private var touchdownQuality = 1.0
    private var bounces = 0
    private var lastOnGround = false
    private var lastSink = 0.0
    /// Continuous time off the ground; short wheel flicker during the rollout is not a bounce.
    private var airTime = 0.0
    private static let bounceTime = 0.5

    public init(mission: MissionDefinition, frame: RunwayFrame, aircraftID: String) {
        self.mission = mission; self.frame = frame; self.aircraftID = aircraftID
        if let problem = mission.validationProblems.first { status = .failed("Invalid mission: \(problem)") }
    }

    public var currentObjective: MissionObjective? {
        status == .inProgress && objectiveIndex < mission.objectives.count ? mission.objectives[objectiveIndex] : nil
    }

    public var isFinished: Bool { status != .inProgress }

    public mutating func noteKill() { kills += 1 }

    // MARK: Update

    /// Advances the mission by one sample. `overstressSeconds` is the envelope monitor's running total.
    @discardableResult
    public mutating func update(sample: FlightSample, targets: [AITarget], overstressSeconds: Double = 0,
                                combat: CombatTally = CombatTally(), radarLockedID: String? = nil) -> [MissionEvent] {
        self.combat = combat
        currentLockID = radarLockedID
        guard status == .inProgress else { return [] }
        if !started {
            started = true; startTime = sample.time; objectiveStart = sample.time
            lastOnGround = sample.onGround
            beginObjective(sample: sample, targets: targets)
        }
        let dt = max(0, sample.time - (startTime + elapsed))
        elapsed = sample.time - startTime
        var events: [MissionEvent] = []

        if let reason = missionFailure(sample: sample, targets: targets) {
            return finish(.failed(reason), events: &events, overstress: overstressSeconds)
        }
        guard let obj = currentObjective else { return events }
        if let limit = obj.timeLimit, sample.time - objectiveStart > limit {
            return finish(.failed("Out of time: \(obj.title)"), events: &events, overstress: overstressSeconds)
        }

        switch evaluate(obj, sample: sample, targets: targets, dt: dt) {
        case .running: break
        case .failed(let reason):
            return finish(.failed(reason), events: &events, overstress: overstressSeconds)
        case .completed(let quality):
            let pts = Int((Double(obj.points) * max(0, min(1, quality))).rounded())
            earned[obj.id] = pts
            events.append(.objectiveCompleted(id: obj.id))
            objectiveIndex += 1
            if objectiveIndex >= mission.objectives.count {
                return finish(.succeeded, events: &events, overstress: overstressSeconds)
            }
            objectiveStart = sample.time
            beginObjective(sample: sample, targets: targets)
        }
        lastOnGround = sample.onGround
        if sample.onGround { airTime = 0 } else { airTime += dt; lastSink = sample.sinkRate }
        return events
    }

    private mutating func beginObjective(sample: FlightSample, targets: [AITarget]) {
        hold = 0; routeIndex = 0; belowTime = 0; outOfBandTime = 0
        loopRef = nil; loopPrev = nil; loopAngle = 0
        errorSum = 0; errorSamples = 0; lostTime = 0; progress = 0
        touchedDown = false; touchdownQuality = 1; bounces = 0
        if let obj = currentObjective, case .flyTo(let wp) = obj.kind {
            initialDistance = Self.distance(sample.positionNED, wp.ned(frame))
        }
        // A landing objective that starts with the wheels already down counts the contact as made.
        if let obj = currentObjective, case .land = obj.kind, sample.onGround { touchedDown = true; progress = 0.6 }
    }

    // MARK: Failure and finish

    private func missionFailure(sample: FlightSample, targets: [AITarget]) -> String? {
        if sample.crashed { return sample.crashReason ?? "Aircraft destroyed" }
        if let limit = mission.timeLimit, elapsed > limit { return "Out of time" }
        if let r = mission.areaRadius {
            let local = frame.local(sample.positionNED)
            if (local.along * local.along + local.right * local.right).squareRoot() > r { return "Left the mission area" }
        }
        if targets.contains(where: { $0.destroyed && $0.role != .hostile }) { return "A friendly or neutral aircraft was destroyed" }
        return nil
    }

    private mutating func finish(_ s: MissionStatus, events: inout [MissionEvent], overstress: Double) -> [MissionEvent] {
        status = s
        let success = s == .succeeded
        var reason: String?
        if case .failed(let r) = s { reason = r }
        let base = earned.values.reduce(0, +)
        var breakdown = earned
        var score = base
        if success {
            let par = max(1, mission.parTime)
            let t = max(0, min(1, (par * 1.5 - elapsed) / (par * 0.5)))
            let bonus = Int((Double(mission.maxBasePoints) * 0.2 * t).rounded())
            breakdown["time bonus"] = bonus
            let penalty = min(base, Int((overstress * 15).rounded()))
            if penalty > 0 { breakdown["overstress penalty"] = -penalty }
            score = max(0, base + bonus - penalty)
        }
        let maxScore = Double(mission.maxBasePoints) * 1.2
        let frac = maxScore > 0 ? Double(score) / maxScore : 0
        let medal: MissionMedal = !success ? .none : frac >= 0.9 ? .gold : frac >= 0.75 ? .silver : frac >= 0.5 ? .bronze : .none
        result = MissionResult(missionID: mission.id, aircraftID: aircraftID, success: success, failureReason: reason,
                               score: score, medal: medal, elapsed: elapsed, objectivesCompleted: earned.count,
                               kills: kills, breakdown: breakdown, combat: combat)
        events.append(success ? .succeeded : .failed(reason: reason ?? "Failed"))
        return events
    }

    // MARK: Objectives

    private enum Evaluation { case running, completed(quality: Double), failed(String) }

    static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    private mutating func evaluate(_ obj: MissionObjective, sample s: FlightSample, targets: [AITarget], dt: Double) -> Evaluation {
        switch obj.kind {
        case .takeoff(let minHeight):
            progress = s.onGround ? 0 : max(0, min(1, s.heightAGL / max(1, minHeight)))
            if !s.onGround && s.heightAGL >= minHeight { return .completed(quality: 1) }
            return .running

        case .reachAltitude(let up, let tolerance, let holdTime):
            let h = frame.local(s.positionNED).up
            if abs(h - up) <= tolerance { hold += dt } else { hold = 0 }
            progress = max(0, min(1, hold / max(0.1, holdTime)))
            return hold >= holdTime ? .completed(quality: 1) : .running

        case .flyTo(let wp):
            let d = Self.distance(s.positionNED, wp.ned(frame))
            progress = initialDistance > 1 ? max(0, min(1, 1 - d / initialDistance)) : 0
            return d <= wp.radius ? .completed(quality: 1) : .running

        case .dropRun(let wp, let maxAGL, let minSpeed, let maxSpeed):
            let d = Self.distance(s.positionNED, wp.ned(frame))
            let speed = Self.distance(s.velocityNED, .zero)
            if d <= wp.radius && !s.onGround && s.heightAGL <= maxAGL && speed >= minSpeed && speed <= maxSpeed {
                return .completed(quality: 1)
            }
            progress = initialDistance > 1 ? max(0, min(1, 1 - d / initialDistance)) : 0
            return .running
        case .loop(let minAGL, let minSpeed):
            if !s.onGround && s.heightAGL < minAGL { return .failed("Too low for the loop") }
            if Self.distance(s.velocityNED, .zero) < minSpeed { return .failed("Lost too much speed in the loop") }
            let vh = SIMD2(s.velocityNED.x, s.velocityNED.y)
            let horiz = (vh.x * vh.x + vh.y * vh.y).squareRoot()
            if loopRef == nil {
                guard horiz > 1 else { progress = 0; return .running }
                loopRef = vh / horiz
            }
            guard let ref = loopRef else { return .running }
            let along = vh.x * ref.x + vh.y * ref.y
            let up = -s.velocityNED.z
            let angle = atan2(up, along)
            if let prev = loopPrev {
                var d = angle - prev
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                loopAngle += d
            }
            loopPrev = angle
            progress = max(0, min(1, abs(loopAngle) / (2 * .pi)))
            return abs(loopAngle) >= 2 * .pi * 0.95 ? .completed(quality: 1) : .running
        case .pickup(let wp, let maxSpeed, let holdTime):
            let d = Self.distance(s.positionNED, wp.ned(frame))
            let speed = Self.distance(s.velocityNED, .zero)
            let stopped = (s.onGround || s.heightAGL < 5) && speed <= maxSpeed && d <= wp.radius
            if stopped { hold += dt } else { hold = 0 }
            progress = max(0, min(1, hold / max(0.1, holdTime)))
            return hold >= holdTime ? .completed(quality: 1) : .running

        case .lowLevelRoute(let points, let minAGL, let maxAGL):
            guard routeIndex < points.count else { return .completed(quality: bandQuality()) }
            if !s.onGround {
                if s.heightAGL < minAGL { belowTime += dt } else { belowTime = max(0, belowTime - dt) }
                if s.heightAGL > maxAGL { outOfBandTime += dt }
            }
            if belowTime > 3 { return .failed("Terrain clearance lost") }
            let wp = points[routeIndex]
            let local = frame.local(s.positionNED), target = frame.local(wp.ned(frame))
            let horizontal = ((local.along - target.along) * (local.along - target.along)
                              + (local.right - target.right) * (local.right - target.right)).squareRoot()
            if horizontal <= wp.radius { routeIndex += 1 }
            progress = Double(routeIndex) / Double(max(1, points.count))
            return routeIndex >= points.count ? .completed(quality: bandQuality()) : .running

        case .land(let aim, let zone, let maxSink):
            return evaluateLanding(sample: s, aim: aim, zone: zone, maxSink: maxSink)

        case .identify(let id, let within, let holdTime):
            guard let t = targets.first(where: { $0.id == id }) else { return .failed("Target lost") }
            if t.destroyed { return .failed("Target destroyed before it was identified") }
            if Self.distance(s.positionNED, t.position) <= within { hold += dt } else { hold = 0 }
            progress = max(0, min(1, hold / max(0.1, holdTime)))
            return hold >= holdTime ? .completed(quality: 1) : .running

        case .destroy(let ids):
            let dead = ids.filter { id in targets.first(where: { $0.id == id })?.destroyed == true }.count
            progress = ids.isEmpty ? 1 : Double(dead) / Double(ids.count)
            return dead == ids.count ? .completed(quality: 1) : .running

        case .survive(let seconds):
            // `dt` is only valid after the first sample, and the crash path has already ended the mission.
            hold += dt
            progress = max(0, min(1, hold / max(0.1, seconds)))
            return hold >= seconds ? .completed(quality: 1) : .running

        case .radarLock(let id, let holdTime):
            guard let t = targets.first(where: { $0.id == id }) else { return .failed("Target lost") }
            if t.destroyed { return .failed("Target destroyed before it was locked") }
            if currentLockID == id { hold += dt } else { hold = 0 }
            progress = max(0, min(1, hold / max(0.1, holdTime)))
            return hold >= holdTime ? .completed(quality: 1) : .running

        case .formation(let leaderID, let slot, let spacing, let tolerance, let holdTime):
            guard let leader = targets.first(where: { $0.id == leaderID }), !leader.destroyed else { return .failed("Lost the formation leader") }
            let err = FormationGeometry.error(ownship: s.positionNED, leader: leader, slot: slot, spacing: spacing)
            if err <= tolerance { hold += dt } else { hold = max(0, hold - 2 * dt) }
            if err > 1_500 { lostTime += dt } else { lostTime = 0 }
            if lostTime > 20 { return .failed("Lost the formation") }
            errorSum += min(err, 2 * tolerance); errorSamples += 1
            progress = max(0, min(1, hold / max(0.1, holdTime)))
            if hold >= holdTime {
                let avg = errorSamples > 0 ? errorSum / Double(errorSamples) : 0
                return .completed(quality: 1 - 0.4 * min(1, avg / max(1e-6, 2 * tolerance)))
            }
            return .running
        }
    }

    private func bandQuality() -> Double {
        // Time above the ceiling costs up to 40 % of the objective.
        1 - min(0.4, outOfBandTime * 0.02)
    }

    private mutating func evaluateLanding(sample s: FlightSample, aim: Double, zone: Double, maxSink: Double) -> Evaluation {
        let local = frame.local(s.positionNED)
        if s.onGround && !lastOnGround && !touchedDown && (airTime >= Self.bounceTime || bounces == 0) {
            // First contact: judge the sink rate recorded in the last airborne sample.
            let sink = max(0, lastSink)
            if local.along < 0 || local.along > frame.length || abs(local.right) > frame.halfWidth + 5 {
                return .failed("Landed off the runway")
            }
            if sink > maxSink { return .failed("Hard landing") }
            touchedDown = true
            let sinkQ = sink <= 1.0 ? 1.0 : 1.0 - 0.4 * min(1, (sink - 1.0) / max(0.1, maxSink - 1.0))
            let off = abs(local.along - aim)
            let zoneQ = off <= zone * 0.5 ? 1.0 : (off <= zone ? 0.9 : 0.75)
            touchdownQuality = max(0.3, sinkQ * zoneQ - 0.1 * Double(bounces))
            progress = 0.6
            return .running
        }
        if touchedDown && !s.onGround {
            // Airborne again: a bounce only once it has stayed off the ground for half a second.
            if airTime >= Self.bounceTime { touchedDown = false; bounces += 1; progress = 0 }
            return .running
        }
        if touchedDown {
            if abs(local.right) > frame.halfWidth + 15 { return .failed("Left the runway") }
            if local.along > frame.length + 150 { return .failed("Ran off the end of the runway") }
            progress = 0.6 + 0.4 * max(0, min(1, 1 - s.groundSpeed / 30))
            if s.groundSpeed < 2 { return .completed(quality: touchdownQuality) }
        }
        return .running
    }
}
