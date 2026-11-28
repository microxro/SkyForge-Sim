// SKYFORGE — Apache-2.0
// AVAudioEngine playback of `ProceduralSynth`. Apple-only; compiles empty elsewhere.
#if canImport(AVFoundation)
import AVFoundation
import Foundation
import os
import SFFlightModel
import SFWeather

/// State owned by the audio render callback. Only the render thread touches `synth`, `mono` and
/// `current`; the main actor hands data over through `shared`.
private final class RenderState: @unchecked Sendable {
    struct Shared: Sendable {
        var params = AudioParameters()
        var events: [AudioEvent] = []
    }
    let shared = OSAllocatedUnfairLock(initialState: Shared())
    var synth: ProceduralSynth
    var mono = [Float](repeating: 0, count: 4_096)     // allocated up front, never on the render thread
    var current = AudioParameters()

    init(sampleRate: Double) { synth = ProceduralSynth(sampleRate: sampleRate) }

    func render(frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) {
        _ = shared.withLockIfAvailableUnchecked { s in
            current = s.params
            if !s.events.isEmpty {
                for e in s.events { synth.trigger(e) }
                s.events.removeAll(keepingCapacity: true)
            }
        }
        var done = 0
        while done < frameCount {                          // chunks, so any callback size renders fully
            let frames = min(frameCount - done, mono.count)
            mono.withUnsafeMutableBufferPointer { synth.render($0.baseAddress!, frames: frames, params: current) }
            for buffer in UnsafeMutableAudioBufferListPointer(abl) {
                guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { dst[done + i] = mono[i] }
            }
            done += frames
        }
    }
}

/// Builds the source node outside any actor, so the render closure is not main-actor isolated and
/// does not trip the Swift 6 executor check when AVAudioEngine calls it on the audio thread.
private func makeSourceNode(format: AVAudioFormat, state: RenderState) -> AVAudioSourceNode {
    AVAudioSourceNode(format: format) { @Sendable _, _, frameCount, audioBufferList -> OSStatus in
        state.render(frameCount: Int(frameCount), abl: audioBufferList)
        return noErr
    }
}

/// Owns the audio graph. Call `update` once per rendered frame from the main actor.
@MainActor
public final class ProceduralAudioEngine {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var renderState: RenderState?
    private var observers: [NSObjectProtocol] = []
    private var model: AudioModel
    private var lastTime = 0.0
    public private(set) var isRunning = false
    private var wantsRunning = false
    /// Master volume 0…1 (the settings screen binds to this).
    public var masterVolume: Float = 0.8 { didSet { engine.mainMixerNode.outputVolume = masterVolume } }
    /// Engine note level 0…1 (settings: audio.engineVolume).
    public var engineVolume: Float = 1
    /// Wind, rain and rumble level 0…1 (settings: audio.ambientVolume).
    public var ambientVolume: Float = 1
    /// False silences the stall horn (settings: gameplay.stallWarningAssist).
    public var stallHornEnabled = true

    public init(config: AircraftConfig = .sf1Trainer) { model = AudioModel(config: config) }

    public func start() throws {
        wantsRunning = true
        guard !isRunning else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        #endif
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let state = RenderState(sampleRate: format.sampleRate)
        let node = makeSourceNode(format: format, state: state)
        renderState = state
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = masterVolume
        try engine.start()
        isRunning = true
        installObservers()
    }

    public func stop() {
        wantsRunning = false
        teardown()
    }

    private func teardown() {
        guard isRunning || source != nil else { return }
        engine.stop()
        if let n = source { engine.detach(n) }   // no node leak per start/stop cycle
        source = nil
        renderState = nil
        isRunning = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    /// Restart after route/config changes and (iOS) interruptions.
    private func installObservers() {
        let nc = NotificationCenter.default
        let restart: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsRunning else { return }
                self.teardown()
                try? self.start()
            }
        }
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: restart))
        #if os(iOS)
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .ended { restart(note) }
        })
        #endif
    }

    public func setConfig(_ config: AircraftConfig) { model = AudioModel(config: config) }

    /// Feed the latest simulation state (once per frame). Ignored while stopped, so no stale events pile up.
    public func update(time: Double, state: AircraftState, outputs: FlightOutputs, inputs: ControlInputs, weather: WeatherEffects) {
        guard isRunning, let rs = renderState else { return }
        // A new flight restarts simulation time at zero, so a backwards step (or a long gap after a
        // restart) must not feed the model a negative or huge dt. Fall back to one frame instead.
        let step = time - lastTime
        let dt = (lastTime == 0 || step <= 0 || step > 0.5) ? 1.0 / 60 : step
        lastTime = time
        let events = model.update(dt: dt, time: time, state: state, outputs: outputs, inputs: inputs, weather: weather)
        var p = model.params
        p.engineGain *= Double(min(max(engineVolume, 0), 1))
        let ambient = Double(min(max(ambientVolume, 0), 1))
        p.windGain *= ambient
        p.rainGain *= ambient
        p.rumbleGain *= ambient
        if !stallHornEnabled { p.stallHorn = false }
        rs.shared.withLock { s in
            s.params = p
            s.events.append(contentsOf: events)
            if s.events.count > 32 { s.events.removeFirst(s.events.count - 32) }
        }
    }
}
#endif
