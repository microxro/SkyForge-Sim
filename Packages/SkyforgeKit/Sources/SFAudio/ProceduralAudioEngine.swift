// SKYFORGE — Apache-2.0
// AVAudioEngine playback of `ProceduralSynth`. Apple-only; compiles empty elsewhere.
#if canImport(AVFoundation)
import AVFoundation
import Foundation
import os
import SFFlightModel
import SFWeather

/// Owns the audio graph. Call `update` once per rendered frame from the main actor.
@MainActor
public final class ProceduralAudioEngine {
    private struct Shared: Sendable {
        var params = AudioParameters()
        var events: [AudioEvent] = []
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var model: AudioModel
    private var lastTime = 0.0
    public private(set) var isRunning = false
    /// Master volume 0…1 (the settings screen binds to this).
    public var masterVolume: Float = 0.8 { didSet { engine.mainMixerNode.outputVolume = masterVolume } }

    public init(config: AircraftConfig = .sf1Trainer) { model = AudioModel(config: config) }

    public func start() throws {
        guard !isRunning else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        #endif
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let shared = self.shared
        var synth = ProceduralSynth(sampleRate: format.sampleRate)
        var mono = [Float](repeating: 0, count: 4_096)      // allocated here, never on the render thread
        var current = AudioParameters()
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            // Take the latest parameters and queued events without blocking the audio thread.
            _ = shared.withLockIfAvailableUnchecked { s in
                current = s.params
                if !s.events.isEmpty {
                    for e in s.events { synth.trigger(e) }
                    s.events.removeAll(keepingCapacity: true)
                }
            }
            let frames = min(Int(frameCount), mono.count)
            mono.withUnsafeMutableBufferPointer { synth.render($0.baseAddress!, frames: frames, params: current) }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in abl {
                guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { dst[i] = mono[i] }
                if frames < Int(frameCount) { for i in frames..<Int(frameCount) { dst[i] = 0 } }
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = masterVolume
        try engine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
    }

    public func setConfig(_ config: AircraftConfig) { model = AudioModel(config: config) }

    /// Feed the latest simulation state (once per frame).
    public func update(time: Double, state: AircraftState, outputs: FlightOutputs, inputs: ControlInputs, weather: WeatherEffects) {
        let dt = lastTime == 0 ? 1.0 / 60 : time - lastTime
        lastTime = time
        let events = model.update(dt: dt, time: time, state: state, outputs: outputs, inputs: inputs, weather: weather)
        let p = model.params
        shared.withLock { s in
            s.params = p
            s.events.append(contentsOf: events)
        }
    }
}
#endif
