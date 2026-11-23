// SKYFORGE — Apache-2.0
// Weapon buttons and the mission result card shown on top of Quick Flight.
#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import SFGameplay

struct WeaponButtons: View {
    let controller: QuickFlightController
    let hasMissiles: Bool
    let hasRadarMissiles: Bool
    @State private var firing = false

    var body: some View {
        VStack(spacing: 8) {
            // Scrolls sideways so the row keeps its width on a phone.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button(firing ? "Cannon: firing" : "Cannon") {
                        firing.toggle(); controller.fireHeld = firing
                    }
                    .buttonStyle(.borderedProminent).tint(firing ? .red : .gray)
                    if hasMissiles {
                        Button("Missile") { controller.launchMissile() }.buttonStyle(.bordered)
                    }
                    if hasRadarMissiles {
                        Button("Radar missile") { controller.launchRadarMissile() }.buttonStyle(.bordered)
                    }
                    Button("Next target") { controller.cycleTarget() }.buttonStyle(.bordered)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button("Radar") { controller.cycleRadar() }.buttonStyle(.bordered)
                    Button("Lock") { controller.lockRadarTarget() }.buttonStyle(.bordered)
                    Button("Flare") { controller.deployFlare() }.buttonStyle(.bordered)
                    Button("Chaff") { controller.deployChaff() }.buttonStyle(.bordered)
                }
            }
        }
        .padding(8)
    }
}

struct MissionResultCard: View {
    let result: MissionResult
    let unlock: String?
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(result.success ? "Mission complete" : "Mission failed").font(.title.bold())
            if let reason = result.failureReason, !result.success { Text(reason).foregroundStyle(.secondary) }
            if result.success {
                Text("Score \(result.score) · \(result.medal.displayName) · \(result.kills) kills")
                Text("Time \(Int(result.elapsed) / 60):\(String(format: "%02d", Int(result.elapsed) % 60))").font(.caption)
            }
            if let unlock { Text(unlock).font(.callout).foregroundStyle(.green) }
            HStack {
                Button("Try again", action: retry).buttonStyle(.bordered)
                Button("Done", action: close).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
#endif
