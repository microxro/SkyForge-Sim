// SKYFORGE — Apache-2.0
// SwiftUI screens for aircraft selection, the mission list and the in-flight mission HUD. They draw
// the plain values from SFGameplay and hold no game logic. Compile-checked on a Mac only.
#if canImport(SwiftUI)
import SwiftUI
import SFGameplay

public struct AircraftPickerView: View {
    public let progress: PlayerProgress
    @Binding public var selectedID: String

    public init(progress: PlayerProgress, selectedID: Binding<String>) {
        self.progress = progress
        self._selectedID = selectedID
    }

    public var body: some View {
        List {
            ForEach(AircraftRole.allCases, id: \.self) { role in
                let items = AircraftCatalog.all.filter { $0.role == role }
                if !items.isEmpty {
                    Section(role.displayName) {
                        ForEach(items) { aircraft in row(aircraft) }
                    }
                }
            }
        }
    }

    private func row(_ a: AircraftSpec) -> some View {
        let unlocked = progress.isUnlocked(a)
        let h = a.highlights
        return Button {
            if unlocked { selectedID = a.id }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(a.name).font(.headline)
                    if a.isMilitary { Image(systemName: "shield.fill").foregroundStyle(.secondary) }
                    Spacer()
                    if selectedID == a.id && unlocked {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    } else if !unlocked {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                }
                Text(a.summary).font(.subheadline).foregroundStyle(.secondary)
                Text("Stall \(Int(h.stallKnots)) kt · Cruise \(Int(h.cruiseKnots)) kt · Vne \(Int(h.neverExceedKnots)) kt · \(Int(h.maxG)) g")
                    .font(.caption).foregroundStyle(.secondary)
                if !unlocked {
                    Text(a.unlock.hint).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
    }
}

public struct MissionListView: View {
    public let progress: PlayerProgress
    public let aircraftID: String
    public let onStart: (MissionDefinition, AircraftSpec) -> Void

    public init(progress: PlayerProgress, aircraftID: String, onStart: @escaping (MissionDefinition, AircraftSpec) -> Void) {
        self.progress = progress
        self.aircraftID = aircraftID
        self.onStart = onStart
    }

    public var body: some View {
        List {
            ForEach(MissionCategory.allCases, id: \.self) { category in
                let items = MissionCatalog.missions(in: category)
                if !items.isEmpty {
                    Section(category.displayName) {
                        ForEach(items) { mission in row(mission) }
                    }
                }
            }
        }
    }

    private func row(_ m: MissionDefinition) -> some View {
        let unlocked = progress.isUnlocked(m)
        let aircraft = AircraftCatalog.spec(id: aircraftID)
        let fits = aircraft.map { progress.canStart(m, in: $0) } ?? false
        let record = progress.records[m.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.title).font(.headline)
                Spacer()
                Text(String(repeating: "★", count: m.difficulty)).font(.caption).foregroundStyle(.secondary)
            }
            Text(m.briefing).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                if let r = record, r.bestMedal != .none {
                    Label("\(r.bestMedal.displayName) · \(r.bestScore)", systemImage: "medal.fill").font(.caption)
                }
                Spacer()
                if !unlocked {
                    Text(m.unlock.hint).font(.caption).foregroundStyle(.orange)
                } else if !fits {
                    Text("Needs: \(m.allowedRoles.map(\.displayName).joined(separator: " or "))")
                        .font(.caption).foregroundStyle(.orange)
                } else if let a = aircraft {
                    Button("Fly") { onStart(m, a) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

public struct MissionHUDView: View {
    public let hud: GameplayHUD

    public init(hud: GameplayHUD) { self.hud = hud }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = hud.objectiveTitle {
                HStack {
                    Text("\(hud.objectiveNumber)/\(hud.objectiveCount)  \(title)").font(.headline)
                    Spacer()
                    Text(hud.timeText).monospacedDigit()
                }
                ProgressView(value: hud.objectiveProgress)
            }
            if !hud.warnings.isEmpty {
                Text(hud.warnings.map(\.callout).joined(separator: "  ")).font(.title3.bold()).foregroundStyle(.red)
            }
            if hud.cannonRounds > 0 || hud.missiles > 0 {
                HStack {
                    Text("GUN \(hud.cannonRounds)")
                    Text("MSL \(hud.missiles)")
                    if let lock = hud.lockText { Text(lock).foregroundStyle(.green) }
                }
                .font(.caption.monospaced())
            }
            switch hud.status {
            case .some(.succeeded): Text("Mission complete").font(.title2.bold()).foregroundStyle(.green)
            case .some(.failed(let reason)): Text("Mission failed: \(reason)").font(.title3.bold()).foregroundStyle(.red)
            default: EmptyView()
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif
