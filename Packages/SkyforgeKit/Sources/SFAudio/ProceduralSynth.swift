// SKYFORGE — Apache-2.0
// Sample generator for `AudioParameters` + `AudioEvent`s. Pure Swift and allocation-free in `render`,
// so it can run on the audio thread and be tested on Linux. Mono output; the engine duplicates it.
import Foundation

public struct ProceduralSynth: Sendable {
    public let sampleRate: Double
    private var enginePhase = 0.0
    private var bladePhase = 0.0
    private var hornPhase = 0.0
    private var noise: UInt32 = 0x1234_5678
    private var windLP = 0.0, windLP2 = 0.0
    private var rumbleLP = 0.0
    private var rainHP = 0.0
    private var cabinLP = 0.0
    private var gustPhase = 0.0
    private var smoothed = AudioParameters()
    private var voices: [Voice] = Array(repeating: Voice(), count: 8)

    private struct Voice: Sendable {
        var kind: Kind = .none
        var age = 0.0
        var amp = 0.0
        var lp = 0.0
        enum Kind: Sendable { case none, touchdown, flap, thunder }
    }

    public init(sampleRate: Double = 48_000) { self.sampleRate = sampleRate }

    public mutating func trigger(_ e: AudioEvent) {
        let slot = voices.firstIndex { $0.kind == .none } ?? 0   // steal the first voice when all are busy
        switch e {
        case .touchdown(let i): voices[slot] = Voice(kind: .touchdown, age: 0, amp: 0.35 + 0.65 * i, lp: 0)
        case .flapMotor: voices[slot] = Voice(kind: .flap, age: 0, amp: 0.25, lp: 0)
        case .thunder(let d): voices[slot] = Voice(kind: .thunder, age: 0, amp: max(0.25, 1 - d / 8_000), lp: 0)
        }
    }

    @inline(__always) private mutating func white() -> Double {
        noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5
        return Double(Int32(bitPattern: noise)) / 2_147_483_648
    }

    /// Fills `out[0..<frames]` with samples in [-1, 1].
    public mutating func render(_ out: UnsafeMutablePointer<Float>, frames: Int, params p: AudioParameters) {
        let dt = 1 / sampleRate
        let twoPi = 2 * Double.pi
        // Per-buffer smoothing so parameter steps never click.
        let k = 1 - exp(-Double(frames) * dt / 0.05)
        smoothed.engineRPM += (p.engineRPM - smoothed.engineRPM) * k
        smoothed.engineGain += (p.engineGain - smoothed.engineGain) * k
        smoothed.engineLoad += (p.engineLoad - smoothed.engineLoad) * k
        smoothed.windGain += (p.windGain - smoothed.windGain) * k
        smoothed.rainGain += (p.rainGain - smoothed.rainGain) * k
        smoothed.rumbleGain += (p.rumbleGain - smoothed.rumbleGain) * k
        smoothed.turbulence += (p.turbulence - smoothed.turbulence) * k
        smoothed.cabinOpenness += (p.cabinOpenness - smoothed.cabinOpenness) * k
        let running = smoothed.engineRPM > 50
        let f0 = smoothed.engineRPM / 60 * 2
        let fb = smoothed.engineRPM / 60 * 2
        // Cabin low-pass: headset-closed ~1.4 kHz … open ~6 kHz.
        let cutoff = 1_400 + 4_600 * smoothed.cabinOpenness
        let cabinA = 1 - exp(-twoPi * cutoff * dt)
        let nyquistHarmonics = max(1, min(14, Int((sampleRate * 0.45) / max(f0, 1))))
        let load = smoothed.engineLoad

        for n in 0..<frames {
            var x = 0.0

            // Engine exhaust: harmonics of the firing frequency, brighter with load, plus the
            // half-order cam/crank rumble and an uneven-firing flutter.
            if running {
                var s = 0.0
                var h = 1
                while h <= nyquistHarmonics {
                    let hf = Double(h)
                    let amp = pow(hf, -0.85) * (h == 1 ? 1 : (0.55 + 0.45 * load))
                    s += amp * sin(hf * enginePhase + 0.7 * hf * hf)
                    h += 1
                }
                s += 0.5 * sin(0.5 * enginePhase)
                let blade = 0.35 * sin(bladePhase) + 0.18 * sin(2 * bladePhase + 0.9)
                x += smoothed.engineGain * 0.22 * (s * 0.55 + blade) + smoothed.engineGain * 0.02 * white()
                enginePhase += twoPi * f0 * dt * (1 + 0.004 * sin(gustPhase * 3.1))
                bladePhase += twoPi * fb * dt
                if enginePhase > 1e6 { enginePhase.formTruncatingRemainder(dividingBy: twoPi) }
                if bladePhase > 1e6 { bladePhase.formTruncatingRemainder(dividingBy: twoPi) }
            }

            // Wind: two-pole low-passed noise, modulated by slow gusts.
            let w = white()
            windLP += (w - windLP) * 0.06
            windLP2 += (windLP - windLP2) * 0.06
            gustPhase += twoPi * 0.4 * dt
            let gust = 1 - smoothed.turbulence * 0.5 * (1 - sin(gustPhase) * sin(gustPhase * 0.37 + 1))
            x += smoothed.windGain * 1.3 * windLP2 * 3.0 * gust

            // Rain: high-passed noise with sparse louder drops.
            let r = white()
            rainHP += (r - rainHP) * 0.5
            let hp = r - rainHP
            let drop = (white() > 0.9985 - 0.002 * smoothed.rainGain) ? 0.8 : 0
            x += smoothed.rainGain * (0.12 * hp + 0.05 * drop * white())

            // Rolling rumble: very low noise.
            rumbleLP += (white() - rumbleLP) * 0.01
            x += smoothed.rumbleGain * 0.9 * rumbleLP

            // Stall horn: ~1.8 kHz with a 3rd harmonic, 4 Hz warble.
            if p.stallHorn {
                hornPhase += twoPi * 1_800 * dt * (1 + 0.02 * sin(gustPhase * 10))
                x += 0.12 * (sin(hornPhase) + 0.4 * sin(3 * hornPhase))
            }

            // One-shot voices.
            for v in 0..<voices.count where voices[v].kind != .none {
                voices[v].age += dt
                let t = voices[v].age
                switch voices[v].kind {
                case .touchdown:
                    let env = exp(-t * 7)
                    let thump = sin(twoPi * (55 + 40 * exp(-t * 12)) * t)
                    let squeak = white()
                    voices[v].lp += (squeak - voices[v].lp) * 0.2
                    x += voices[v].amp * env * (0.7 * thump + 0.35 * voices[v].lp)
                    if t > 0.9 { voices[v].kind = .none }
                case .flap:
                    let env = min(1, t * 20) * (t < 1.4 ? 1 : max(0, 1 - (t - 1.4) * 8))
                    x += voices[v].amp * env * (0.4 * sin(twoPi * 160 * t) + 0.2 * sin(twoPi * 480 * t)) * (0.7 + 0.3 * white())
                    if t > 1.6 { voices[v].kind = .none }
                case .thunder:
                    let env = min(1, t * 3) * exp(-t * 0.7)
                    voices[v].lp += (white() - voices[v].lp) * 0.015
                    x += voices[v].amp * env * voices[v].lp * 6 * (0.6 + 0.4 * sin(twoPi * 3 * t))
                    if t > 7 { voices[v].kind = .none }
                case .none: break
                }
            }

            // Cabin filter on the whole mix, then soft clip.
            cabinLP += (x - cabinLP) * cabinA
            let y = tanh(cabinLP * 1.1)
            out[n] = Float(y)
        }
    }
}
