// SKYFORGE — Apache-2.0
// PC-style settings menu. Values live in SFSettings (tested on Linux); this view edits them and saves on change.
#if canImport(SwiftUI)
import SwiftUI
import SFSettings

/// Loads and saves SkySettings in UserDefaults. Unreadable data falls back to defaults.
@MainActor @Observable
public final class SettingsStore {
    public var settings: SkySettings
    public private(set) var saveError: String?
    private static let key = "skyforge.settings.v1"

    public init() {
        settings = SettingsCodec.decode(UserDefaults.standard.data(forKey: Self.key))
    }

    public func save() {
        do {
            let data = try SettingsCodec.encode(settings)
            UserDefaults.standard.set(data, forKey: Self.key)
            saveError = nil
        } catch {
            saveError = "Settings could not be saved (\(error.localizedDescription)). They apply until the app quits."
        }
    }
}

/// Features whose renderer is not in this build. The UI shows them disabled instead of pretending they work.
public enum SettingsAvailability {
    /// Flips to true when the ray-tracing renderer lands.
    public static let rayTracing = false
}

public struct SettingsView: View {
    @State private var store = SettingsStore()

    public init() {}

    public var body: some View {
        Form {
            graphicsSection
            performanceSection
            audioSection
            controlsSection
            gameplaySection
            hudSection
            unitsSection
            accessibilitySection
            languageSection
            if let error = store.saveError {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: store.settings) { _, _ in store.save() }
    }

    // MARK: Graphics

    private var presetBinding: Binding<GraphicsPreset> {
        Binding(get: { store.settings.graphics.preset },
                set: { store.settings.applyPreset($0) })
    }

    private var graphicsSection: some View {
        Section {
            Picker("Preset", selection: presetBinding) {
                Text("Low").tag(GraphicsPreset.low)
                Text("Medium").tag(GraphicsPreset.medium)
                Text("High").tag(GraphicsPreset.high)
                Text("Ultra").tag(GraphicsPreset.ultra)
                Text("Custom").tag(GraphicsPreset.custom)
            }
            slider("Resolution scale", $store.settings.graphics.resolutionScale, 0.5...1.0)
            Picker("Anti-aliasing", selection: $store.settings.graphics.antialiasing) {
                ForEach(AntiAliasing.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            Toggle("Wide edge anti-aliasing", isOn: $store.settings.graphics.wideEdgeAA)
            qualityPicker("Shadows", $store.settings.graphics.shadows)
            qualityPicker("Clouds", $store.settings.graphics.clouds)
            qualityPicker("Water", $store.settings.graphics.water)
            slider("Trees and grass", $store.settings.graphics.vegetationDensity, 0.25...2.0)
            slider("Buildings", $store.settings.graphics.buildingDensity, 0.25...2.0)
            slider("Level of detail distance", $store.settings.graphics.lodDistance, 0.25...2.0)
            Picker("Ray tracing", selection: $store.settings.graphics.rayTracing) {
                Text("Off").tag(RayTracingMode.off)
                Text("Ray traced").tag(RayTracingMode.rayTraced)
                Text("Path traced").tag(RayTracingMode.pathTraced)
            }
            .disabled(!SettingsAvailability.rayTracing)
            if store.settings.graphics.rayTracing.isEnabled {
                Toggle("RT shadows", isOn: $store.settings.graphics.rayTracingFeatures.shadows)
                Toggle("RT reflections", isOn: $store.settings.graphics.rayTracingFeatures.reflections)
                Toggle("RT ambient occlusion", isOn: $store.settings.graphics.rayTracingFeatures.ambientOcclusion)
                if store.settings.graphics.rayTracing == .pathTraced {
                    Toggle("Global illumination", isOn: $store.settings.graphics.rayTracingFeatures.globalIllumination)
                }
            }
            if !SettingsAvailability.rayTracing {
                Text("Ray tracing needs the ray-tracing renderer, which is not in this build.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Picker("Frame rate cap", selection: $store.settings.graphics.frameRateCap) {
                Text("30 fps").tag(FrameRateCap.fps30)
                Text("60 fps").tag(FrameRateCap.fps60)
                Text("120 fps").tag(FrameRateCap.fps120)
                Text("Unlimited").tag(FrameRateCap.unlimited)
            }
            Toggle("Vertical sync", isOn: $store.settings.graphics.vsync)
        } header: {
            Text("Graphics")
        }
    }

    // MARK: Performance, audio, controls, gameplay, HUD, units, accessibility, language

    private var performanceSection: some View {
        Section {
            Toggle("Frame rate overlay", isOn: $store.settings.performance.showFPSOverlay)
            Toggle("GPU time overlay", isOn: $store.settings.performance.showGPUTime)
            Toggle("Adaptive quality", isOn: $store.settings.performance.adaptiveQuality)
        } header: { Text("Performance") }
    }

    private var audioSection: some View {
        Section {
            slider("Master", $store.settings.audio.masterVolume, 0...1)
            slider("Engine", $store.settings.audio.engineVolume, 0...1)
            slider("Ambience", $store.settings.audio.ambientVolume, 0...1)
        } header: { Text("Audio") }
    }

    private var controlsSection: some View {
        Section {
            NavigationLink("Key bindings and buttons") { BindingsView() }
            slider("Touch sensitivity", $store.settings.controls.touchSensitivity, 0.1...3.0)
            slider("Dead zone scale", $store.settings.controls.deadZoneScale, 0...3.0)
            Toggle("Invert pitch", isOn: $store.settings.controls.invertPitch)
        } header: { Text("Controls") }
    }

    private var gameplaySection: some View {
        Section {
            Picker("Realism", selection: $store.settings.gameplay.realism) {
                Text("Arcade").tag(RealismLevel.arcade)
                Text("Standard").tag(RealismLevel.standard)
                Text("Simulation").tag(RealismLevel.simulation)
            }
            Toggle("Auto trim", isOn: $store.settings.gameplay.autoTrim)
            Toggle("Auto rudder", isOn: $store.settings.gameplay.autoRudder)
            Toggle("Stall warning assist", isOn: $store.settings.gameplay.stallWarningAssist)
        } header: { Text("Gameplay") }
    }

    private var hudSection: some View {
        Section {
            Toggle("Show HUD", isOn: $store.settings.hud.showHUD)
            slider("Instrument scale", $store.settings.hud.instrumentScale, 0.5...2.0)
            Toggle("Airport labels", isOn: $store.settings.hud.showAirportLabels)
            Toggle("Traffic labels", isOn: $store.settings.hud.showTrafficLabels)
        } header: { Text("HUD") }
    }

    private var unitsSection: some View {
        Section {
            Picker("Speed", selection: $store.settings.units.speed) {
                Text("Knots").tag(SpeedUnit.knots)
                Text("km/h").tag(SpeedUnit.kph)
                Text("mph").tag(SpeedUnit.mph)
            }
            Picker("Altitude", selection: $store.settings.units.altitude) {
                Text("Feet").tag(AltitudeUnit.feet)
                Text("Metres").tag(AltitudeUnit.metres)
            }
            Picker("Pressure", selection: $store.settings.units.pressure) {
                Text("inHg").tag(PressureUnit.inHg)
                Text("hPa").tag(PressureUnit.hPa)
            }
        } header: { Text("Units") }
    }

    private var accessibilitySection: some View {
        Section {
            slider("Text size", $store.settings.accessibility.textScale, 0.75...2.0)
            Toggle("Reduce motion", isOn: $store.settings.accessibility.reduceMotion)
            Toggle("High-contrast HUD", isOn: $store.settings.accessibility.highContrastHUD)
            Picker("Colour vision", selection: $store.settings.accessibility.colourblindMode) {
                Text("None").tag(ColourblindMode.none)
                Text("Protanopia").tag(ColourblindMode.protanopia)
                Text("Deuteranopia").tag(ColourblindMode.deuteranopia)
                Text("Tritanopia").tag(ColourblindMode.tritanopia)
            }
            Toggle("Subtitles", isOn: $store.settings.accessibility.subtitles)
        } header: { Text("Accessibility") }
    }

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $store.settings.language) {
                Text("English").tag("en")
            }
        } header: { Text("Language") } footer: {
            Text("More languages arrive with localisation.")
        }
    }

    // MARK: Helpers

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(value.wrappedValue, format: .number.precision(.fractionLength(2)))")
                .font(.callout.monospacedDigit())
            Slider(value: value, in: range)
        }
    }

    private func qualityPicker(_ title: String, _ value: Binding<QualityLevel>) -> some View {
        Picker(title, selection: value) {
            ForEach(QualityLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
    }
}
#endif
