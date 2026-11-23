// SKYFORGE — Apache-2.0
// Flight state -> sound parameters. Pure Swift (no AVFoundation), so it is unit-tested on Linux.
// The synth (`ProceduralSynth`) turns these parameters into samples; `ProceduralAudioEngine` plays them.
// All sounds are synthesized: the app ships no audio assets (no licences, ~0 bytes).
import Foundation
import SFMath
import SFFlightModel
import SFWeather

/// One-shot sounds raised by `AudioModel`.
public enum AudioEvent: Sendable, Equatable {
    /// Main-gear contact. `intensity` 0 (feather) … 1 (>= 3 m/s sink, a hard landing).
    case touchdown(intensity: Double)
    /// Flap motor run (when the commanded flap setting changes by more than 3 %).
    case flapMotor
    /// Thunder clap; `distance` in metres sets the delay already applied and the low-pass.
    case thunder(distance: Double)
}

/// Continuous controls for the synth, refreshed every frame (all gains 0…1, frequencies in Hz).
public struct AudioParameters: Sendable, Equatable {
    public var engineRPM: Double = 0
    public var engineLoad: Double = 0          // 0…1, brightens and loudens the exhaust note
    public var engineGain: Double = 0
    /// Engine cylinder firing frequency (4-cylinder, 4-stroke: 2 firings per revolution).
    public var firingHz: Double { profile.firingHz(engineRPM) }
    /// Propeller blade-pass frequency (two blades).
    public var bladePassHz: Double { profile.bladePassHz(engineRPM) }
    public var windGain: Double = 0
    public var turbulence: Double = 0          // 0…1 gust modulation depth
    public var rainGain: Double = 0
    public var rumbleGain: Double = 0          // rolling on the ground
    public var stallHorn: Bool = false
    /// 0 = headset/closed cabin … 1 = wide open (raises the low-pass cutoff on engine and wind).
    public var cabinOpenness: Double = 0.15
    /// Engine character for the current aircraft (set by `AudioModel` each update).
    public var profile: EngineProfile = .inline4
    public init() {}

    /// Copy with every value finite and in range (NaN becomes 0), safe to hand to the audio thread.
    public var sanitized: AudioParameters {
        func f(_ x: Double, _ hi: Double) -> Double { x.isFinite ? min(max(x, 0), hi) : 0 }
        var p = self
        p.engineRPM = f(engineRPM, 20_000); p.engineLoad = f(engineLoad, 1); p.engineGain = f(engineGain, 1)
        p.windGain = f(windGain, 1); p.turbulence = f(turbulence, 1); p.rainGain = f(rainGain, 1)
        p.rumbleGain = f(rumbleGain, 1); p.cabinOpenness = f(cabinOpenness, 1)
        return p
    }
}

/// Turns the simulation state into `AudioParameters` and edge-triggered `AudioEvent`s.
public struct AudioModel: Sendable {
    public static let idleRPM = 700.0
    public var config: AircraftConfig
    public private(set) var params = AudioParameters()
    private var rpm: Double
    private var lastSink = 0.0
    private var wasOnGround = true
    private var lastFlaps = 0.0
    private var flapsWereMoving = false
    private var lastUpdateTime = 0.0
    private var lastTouchdownTime = -Double.infinity
    private var lastScheduledFlash = -1.0
    private var thunderQueue: [(time: Double, distance: Double)] = []

    public init(config: AircraftConfig = .sf1Trainer) {
        self.config = config
        rpm = Self.idleRPM
    }

    /// Steady-state RPM of a fixed-pitch propeller: set by throttle, pulled up a little by airspeed.
    public static func targetRPM(throttle: Double, trueAirspeed v: Double, maxRPM: Double) -> Double {
        let t = min(max(throttle, 0), 1)
        let frac = min(1, 0.80 * pow(t, 0.8) + 0.20 * t * min(v / 70, 1))
        return idleRPM + (maxRPM - idleRPM) * frac
    }

    /// Wind-noise gain from airspeed (aerodynamic noise power ~ v^4, amplitude ~ v^2), saturating at 1.
    public static func windGain(trueAirspeed v: Double, openness: Double) -> Double {
        let g = pow(min(v / 80, 1.5), 2) * (0.45 + 0.55 * openness)
        return min(max(g, 0), 1)
    }

    /// Advances the model by `dt` seconds and returns the one-shots raised in that step.
    /// `time` is the simulation clock (used for gusts and thunder scheduling).
    public mutating func update(dt: Double, time: Double, state s: AircraftState, outputs o: FlightOutputs,
                                inputs c: ControlInputs, weather w: WeatherEffects, eventSeed: UInt64 = 1) -> [AudioEvent] {
        var events: [AudioEvent] = []
        // Non-finite inputs (NaN throttle, inf dt...) must never reach the filters: NaN would persist forever.
        let dt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let time = time.isFinite ? time : lastUpdateTime
        let tas = o.trueAirspeed.isFinite ? max(0, o.trueAirspeed) : 0
        let throttle = c.throttle.isFinite ? min(max(c.throttle, 0), 1) : 0
        let flaps = c.flaps.isFinite ? c.flaps : lastFlaps
        let alpha = o.alpha.isFinite ? o.alpha : 0
        let sinkNow = s.velocityNED.z.isFinite ? s.velocityNED.z : 0
        let ground = hypot(s.velocityNED.x.isFinite ? s.velocityNED.x : 0, s.velocityNED.y.isFinite ? s.velocityNED.y : 0)
        if time < lastUpdateTime { thunderQueue.removeAll(); lastScheduledFlash = -1; lastTouchdownTime = -.infinity }   // clock went backwards
        lastUpdateTime = time

        // Engine: first-order lag toward the target (the crank and prop have inertia).
        let target = Self.targetRPM(throttle: throttle, trueAirspeed: tas, maxRPM: config.maxRPM)
        rpm += (target - rpm) * (1 - exp(-dt / 0.55))
        params.engineRPM = rpm
        params.profile = EngineProfile.forAircraft(config)
        params.engineLoad = throttle
        params.engineGain = 0.55 + 0.35 * params.engineLoad

        // Wind: relative airflow plus ambient wind and gusts when parked or slow.
        let ambient = w.windSpeed(at: time)
        let airflow = max(tas, ambient * 0.6)
        params.windGain = Self.windGain(trueAirspeed: airflow, openness: params.cabinOpenness)
        params.turbulence = w.turbulence

        // Rain on the canopy (not when the precipitation is snow, which is nearly silent).
        switch w.precipitation {
        case .none: params.rainGain = 0
        case .snow: params.rainGain = 0.1 * w.precipitationIntensity
        case .drizzle: params.rainGain = 0.3 * w.precipitationIntensity
        case .rain: params.rainGain = 0.2 + 0.8 * w.precipitationIntensity
        case .hail: params.rainGain = min(1, 0.4 + 0.8 * w.precipitationIntensity)
        }

        // Ground rumble scales with ground speed while on the wheels.
        params.rumbleGain = o.weightOnWheels ? min(1, ground / 40) : 0

        // Stall horn from 92 % of the stall angle of attack in flight.
        params.stallHorn = !o.weightOnWheels && (alpha > config.stallAlpha * 0.92 || o.stalled)

        // Touchdown: rising edge of weight-on-wheels, using the previous frame's sink rate.
        if o.weightOnWheels && !wasOnGround && time - lastTouchdownTime > 0.5 {   // cooldown: gear chatter
            events.append(.touchdown(intensity: min(1, max(0.05, lastSink / 3))))
            lastTouchdownTime = time
        }
        if !o.weightOnWheels { lastSink = max(0, sinkNow) }
        wasOnGround = o.weightOnWheels

        // Flap motor.
        let moving = abs(flaps - lastFlaps) > 0.0005
        if moving && !flapsWereMoving { events.append(.flapMotor) }
        flapsWereMoving = moving
        lastFlaps = flaps

        // Thunder: each flash is scheduled once; the clap arrives after distance / speed of sound.
        if w.thunderstorm {
            if let f = w.nextLightning(after: time, seed: eventSeed), f > lastScheduledFlash {
                lastScheduledFlash = f
                let dist = 1_000 + 5_000 * WeatherEffects.unit(eventSeed ^ 0xA5A5, UInt64(f * 10))
                if thunderQueue.count < 8 { thunderQueue.append((f + dist / 343, dist)) }
            }
            while let first = thunderQueue.first, time >= first.time {
                events.append(.thunder(distance: first.distance))
                thunderQueue.removeFirst()
            }
        } else {
            thunderQueue.removeAll()
        }
        return events
    }
}
