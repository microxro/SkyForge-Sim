// SKYFORGE — Apache-2.0
// Pure-Swift settings model. Linux-testable. The SwiftUI menu lives in SFUI and the renderers read these
// values through their own adapters. Key bindings are not stored here: they stay in SFInput's BindingProfile.
import Foundation

public enum QualityLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case off, low, medium, high, ultra
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: QualityLevel, b: QualityLevel) -> Bool { a.rank < b.rank }
}

public enum AntiAliasing: String, Codable, Sendable, CaseIterable {
    case off, fxaa, smaa, taa
}

/// Overall ray tracing intensity. The renderer clamps this to what the device supports (unsupported devices get `off`).
public enum RayTracingMode: String, Codable, Sendable, CaseIterable {
    case off
    /// Hardware ray traced shadows, reflections, ambient occlusion (per-feature toggles below).
    case rayTraced
    /// Path traced: adds global illumination on top of the ray traced features.
    case pathTraced

    public var isEnabled: Bool { self != .off }

    /// Older builds stored "reflections" and "full" before this setting existed; both now mean ray traced.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "rayTraced", "reflections", "full": self = .rayTraced
        case "pathTraced": self = .pathTraced
        default: self = .off
        }
    }
}

/// Which ray traced features are on when `RayTracingMode` is enabled.
public struct RayTracingFeatures: Codable, Sendable, Equatable {
    public var shadows = true
    public var reflections = true
    public var ambientOcclusion = true
    /// Only applies at `pathTraced`; ignored at `rayTraced`.
    public var globalIllumination = true
    public init() {}
}

public enum FrameRateCap: Int, Codable, Sendable, CaseIterable {
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120
    case unlimited = 0
}

public enum GraphicsPreset: String, Codable, Sendable, CaseIterable {
    case low, medium, high, ultra, custom
}

public enum RealismLevel: String, Codable, Sendable, CaseIterable {
    case arcade, standard, simulation
}

public enum ColourblindMode: String, Codable, Sendable, CaseIterable {
    case none, protanopia, deuteranopia, tritanopia
}

public enum SpeedUnit: String, Codable, Sendable, CaseIterable { case knots, kph, mph }
public enum AltitudeUnit: String, Codable, Sendable, CaseIterable { case feet, metres }
public enum PressureUnit: String, Codable, Sendable, CaseIterable { case hPa, inHg }

public struct GraphicsSettings: Codable, Sendable, Equatable {
    public var preset: GraphicsPreset = .high
    /// Internal render resolution as a fraction of the drawable (0.5 ... 1.0).
    public var resolutionScale: Double = 1.0
    public var antialiasing: AntiAliasing = .taa
    /// Wide-edge AA flag from PR #130.
    public var wideEdgeAA = false
    public var shadows: QualityLevel = .high
    public var clouds: QualityLevel = .high
    public var water: QualityLevel = .high
    /// Tree and grass density multiplier (0.25 ... 2.0).
    public var vegetationDensity: Double = 1.0
    /// Building density multiplier (0.25 ... 2.0).
    public var buildingDensity: Double = 1.0
    /// Level-of-detail distance multiplier (0.25 ... 2.0). Higher means detail holds further out.
    public var lodDistance: Double = 1.0
    /// Ray tracing is opt-in and off in every preset.
    public var rayTracing: RayTracingMode = .off
    /// Per-feature ray tracing toggles. Only read when `rayTracing` is enabled.
    public var rayTracingFeatures = RayTracingFeatures()
    public var frameRateCap: FrameRateCap = .fps60
    public var vsync = true
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case preset, resolutionScale, antialiasing, wideEdgeAA, shadows, clouds, water
        case vegetationDensity, buildingDensity, lodDistance, rayTracing, rayTracingFeatures, frameRateCap, vsync
    }

    /// Settings files written before ray tracing features existed have no `rayTracingFeatures` key; they get the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decode(GraphicsPreset.self, forKey: .preset)
        resolutionScale = try c.decode(Double.self, forKey: .resolutionScale)
        antialiasing = try c.decode(AntiAliasing.self, forKey: .antialiasing)
        wideEdgeAA = try c.decode(Bool.self, forKey: .wideEdgeAA)
        shadows = try c.decode(QualityLevel.self, forKey: .shadows)
        clouds = try c.decode(QualityLevel.self, forKey: .clouds)
        water = try c.decode(QualityLevel.self, forKey: .water)
        vegetationDensity = try c.decode(Double.self, forKey: .vegetationDensity)
        buildingDensity = try c.decode(Double.self, forKey: .buildingDensity)
        lodDistance = try c.decode(Double.self, forKey: .lodDistance)
        rayTracing = try c.decodeIfPresent(RayTracingMode.self, forKey: .rayTracing) ?? .off
        rayTracingFeatures = try c.decodeIfPresent(RayTracingFeatures.self, forKey: .rayTracingFeatures) ?? RayTracingFeatures()
        frameRateCap = try c.decode(FrameRateCap.self, forKey: .frameRateCap)
        vsync = try c.decode(Bool.self, forKey: .vsync)
    }
}

public struct PerformanceSettings: Codable, Sendable, Equatable {
    public var showFPSOverlay = false
    public var showGPUTime = false
    /// Lets the SFPerf quality governor lower settings to hold the frame rate.
    public var adaptiveQuality = true
    public init() {}
}

public struct AudioSettings: Codable, Sendable, Equatable {
    public var masterVolume: Double = 0.8
    public var engineVolume: Double = 0.8
    public var ambientVolume: Double = 0.6
    public init() {}
}

public struct ControlsSettings: Codable, Sendable, Equatable {
    /// Name of the active BindingProfile (SFInput).
    public var activeProfileName = "Default"
    /// Multiplies touch tilt sensitivity (0.1 ... 3.0).
    public var touchSensitivity: Double = 1.0
    /// Scales every axis inner dead zone (0.0 ... 3.0).
    public var deadZoneScale: Double = 1.0
    public var invertPitch = false
    public init() {}
}

public struct GameplaySettings: Codable, Sendable, Equatable {
    public var realism: RealismLevel = .standard
    public var autoTrim = false
    public var autoRudder = false
    public var stallWarningAssist = true
    public init() {}
}

public struct HUDSettings: Codable, Sendable, Equatable {
    public var showHUD = true
    /// Instrument panel scale (0.5 ... 2.0).
    public var instrumentScale: Double = 1.0
    public var showAirportLabels = true
    public var showTrafficLabels = true
    public init() {}
}

public struct UnitSettings: Codable, Sendable, Equatable {
    public var speed: SpeedUnit = .knots
    public var altitude: AltitudeUnit = .feet
    public var pressure: PressureUnit = .inHg
    public init() {}
}

public struct AccessibilitySettings: Codable, Sendable, Equatable {
    /// UI text scale (0.75 ... 2.0).
    public var textScale: Double = 1.0
    public var reduceMotion = false
    public var highContrastHUD = false
    public var colourblindMode: ColourblindMode = .none
    public var subtitles = false
    public init() {}
}

public struct SkySettings: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public var schemaVersion: Int = SkySettings.schemaVersion
    public var graphics = GraphicsSettings()
    public var performance = PerformanceSettings()
    public var audio = AudioSettings()
    public var controls = ControlsSettings()
    public var gameplay = GameplaySettings()
    public var hud = HUDSettings()
    public var units = UnitSettings()
    public var accessibility = AccessibilitySettings()
    /// BCP-47 language tag for the UI.
    public var language = "en"
    public init() {}

    /// Returns a copy with every numeric value clamped to its documented range.
    public func clamped() -> SkySettings {
        var s = self
        s.graphics.resolutionScale = Self.clamp(s.graphics.resolutionScale, 0.5, 1.0)
        s.graphics.vegetationDensity = Self.clamp(s.graphics.vegetationDensity, 0.25, 2.0)
        s.graphics.buildingDensity = Self.clamp(s.graphics.buildingDensity, 0.25, 2.0)
        s.graphics.lodDistance = Self.clamp(s.graphics.lodDistance, 0.25, 2.0)
        s.audio.masterVolume = Self.clamp(s.audio.masterVolume, 0, 1)
        s.audio.engineVolume = Self.clamp(s.audio.engineVolume, 0, 1)
        s.audio.ambientVolume = Self.clamp(s.audio.ambientVolume, 0, 1)
        s.controls.touchSensitivity = Self.clamp(s.controls.touchSensitivity, 0.1, 3.0)
        s.controls.deadZoneScale = Self.clamp(s.controls.deadZoneScale, 0, 3.0)
        s.hud.instrumentScale = Self.clamp(s.hud.instrumentScale, 0.5, 2.0)
        s.accessibility.textScale = Self.clamp(s.accessibility.textScale, 0.75, 2.0)
        return s
    }

    /// Replaces the graphics block with a preset. `.custom` keeps the current values.
    public mutating func applyPreset(_ preset: GraphicsPreset) {
        guard preset != .custom else { graphics.preset = .custom; return }
        var g = GraphicsSettings()
        g.preset = preset
        switch preset {
        case .low:
            g.resolutionScale = 0.75; g.antialiasing = .fxaa; g.shadows = .low; g.clouds = .low; g.water = .low
            g.vegetationDensity = 0.5; g.buildingDensity = 0.5; g.lodDistance = 0.75
        case .medium:
            g.resolutionScale = 0.9; g.antialiasing = .smaa; g.shadows = .medium; g.clouds = .medium; g.water = .medium
            g.vegetationDensity = 0.75; g.buildingDensity = 0.75; g.lodDistance = 1.0
        case .high:
            break
        case .ultra:
            g.resolutionScale = 1.0; g.antialiasing = .taa; g.shadows = .ultra; g.clouds = .ultra; g.water = .ultra
            g.vegetationDensity = 1.5; g.buildingDensity = 1.5; g.lodDistance = 1.5
        case .custom:
            break
        }
        graphics = g
    }
}

/// Encodes and decodes settings. Corrupt or unreadable data falls back to defaults instead of failing.
public enum SettingsCodec {
    public static func encode(_ settings: SkySettings) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(settings.clamped())
    }

    public static func decode(_ data: Data?) -> SkySettings {
        // The saved object is merged over the defaults before decoding. A plain decode throws on any key the
        // file predates, which would discard every setting; with the merge, only the missing fields take defaults.
        guard let data,
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (saved["schemaVersion"] as? Int ?? 1) <= SkySettings.schemaVersion,
              let defaultsData = try? JSONEncoder().encode(SkySettings()),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: mergeSettings(defaults, over: saved)),
              let s = try? JSONDecoder().decode(SkySettings.self, from: merged) else {
            return SkySettings()
        }
        return s.clamped()
    }

    /// Overlays `saved` on `base`, recursing into nested objects so a missing nested key keeps its default.
    private static func mergeSettings(_ base: [String: Any], over saved: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in saved {
            if let inner = value as? [String: Any], let baseInner = base[key] as? [String: Any] {
                out[key] = mergeSettings(baseInner, over: inner)
            } else {
                out[key] = value
            }
        }
        return out
    }
}

extension SkySettings {
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard v.isFinite else { return lo }
        return min(hi, max(lo, v))
    }
}
