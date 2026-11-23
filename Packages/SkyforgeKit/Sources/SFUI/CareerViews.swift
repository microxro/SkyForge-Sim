// SKYFORGE — Apache-2.0
// Career hub: profile, hangar, achievements and campaigns. Logic lives in SFCareer (tested on Linux);
// these views only present a CareerState and report purchases back through `onChange`.
#if canImport(SwiftUI)
import SwiftUI
import SFCareer

public struct CareerHubView: View {
    @Binding var career: CareerState
    var logbook: Logbook
    var onChange: () -> Void

    public init(career: Binding<CareerState>, logbook: Logbook = Logbook(), onChange: @escaping () -> Void = {}) {
        self._career = career
        self.logbook = logbook
        self.onChange = onChange
    }

    public var body: some View {
        TabView {
            CareerProfileView(career: career)
                .tabItem { Label("Pilot", systemImage: "person.crop.circle") }
            HangarView(career: $career, onChange: onChange)
                .tabItem { Label("Hangar", systemImage: "airplane") }
            LogbookView(logbook: logbook)
                .tabItem { Label("Logbook", systemImage: "book.closed") }
            CampaignListView(career: career)
                .tabItem { Label("Campaigns", systemImage: "flag.checkered") }
            AchievementListView(career: career)
                .tabItem { Label("Awards", systemImage: "rosette") }
        }
    }
}

/// Loads the saved career, shows the hub and writes purchases back to disk.
public struct CareerScreen: View {
    @State private var career = CareerState()
    @State private var logbook = Logbook()
    @State private var loadError: String?
    private let store = SaveStore(url: SaveStore.defaultURL)
    public init() {}
    public var body: some View {
        Group {
            if let loadError { Text(loadError).padding() }
            else { CareerHubView(career: $career, logbook: logbook) { try? store.save(career) } }
        }
        .navigationTitle("Pilot career")
        .task {
            do { career = try store.load() } catch { loadError = "Your career file could not be read, so it was left untouched." }
            // The logbook is read-only here. A missing or unreadable file just shows an empty logbook.
            logbook = (try? LogbookStore(url: LogbookStore.defaultURL).load()) ?? Logbook()
        }
    }
}

struct CareerProfileView: View {
    let career: CareerState
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(career.pilotName).font(.title2.bold())
                    Text("\(career.rank.title) · Level \(career.level)").foregroundStyle(.secondary)
                    ProgressView(value: Progression.levelProgress(xp: career.xp))
                        .accessibilityLabel("Progress to next level")
                    Text("\(career.xp) XP · \(career.credits) credits").font(.callout.monospacedDigit())
                }
            }
            Section("Lifetime") {
                stat("Flights", "\(career.stats.flights)")
                stat("Landings", "\(career.stats.landings)")
                stat("Hours flown", String(format: "%.1f", career.stats.flightSeconds / 3600))
                stat("Distance", String(format: "%.0f km", career.stats.distanceKm))
                stat("Jobs completed", "\(career.stats.jobsCompleted)")
                stat("Kills", "\(career.stats.kills)")
                stat("Daily streak", "\(career.stats.dailyStreak) (best \(career.stats.bestDailyStreak))")
            }
        }
    }
    func stat(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).monospacedDigit().foregroundStyle(.secondary) }
    }
}

struct HangarView: View {
    @Binding var career: CareerState
    var onChange: () -> Void
    @State private var message: String?

    var body: some View {
        List {
            if let message { Section { Text(message).font(.callout) } }
            ForEach(Economy.catalog) { a in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(a.name).font(.headline)
                        if a.isMilitary { Text("MIL").font(.caption2.bold()).padding(.horizontal, 5).background(.red.opacity(0.25), in: Capsule()) }
                        Spacer()
                        trailing(for: a)
                    }
                    Text("\(a.seats) seat · \(Int(a.rangeKm)) km range · \(Int(a.cruiseKts)) kt cruise")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder func trailing(for a: HangarAircraft) -> some View {
        if career.ownedAircraft.contains(a.id) {
            Label("Owned", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if career.level < a.unlockLevel {
            Label("Level \(a.unlockLevel)", systemImage: "lock.fill").foregroundStyle(.secondary)
        } else {
            Button("Buy \(a.purchasePrice)") { buy(a) }.buttonStyle(.borderedProminent)
        }
    }

    func buy(_ a: HangarAircraft) {
        do { try career.buy(aircraftID: a.id); message = "Bought \(a.name)"; onChange() }
        catch CareerState.PurchaseError.insufficientFunds(let short) { message = "Need \(short) more credits" }
        catch { message = "Cannot buy \(a.name) right now" }
    }
}

struct CampaignListView: View {
    let career: CareerState
    var body: some View {
        List(Campaign.all) { c in
            let p = career.progress(in: c)
            VStack(alignment: .leading, spacing: 6) {
                Text(c.title).font(.headline)
                Text(c.summary).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(p.completed), total: Double(max(1, p.total)))
                Text(p.nextStage.map { "Next: \($0.title)" } ?? "Complete").font(.caption)
            }
        }
    }
}

struct AchievementListView: View {
    let career: CareerState
    var body: some View {
        List(AchievementCatalog.all) { a in
            let done = career.unlockedAchievements.contains(a.id)
            HStack {
                Image(systemName: done ? "rosette" : "lock").foregroundStyle(done ? .yellow : .secondary)
                VStack(alignment: .leading) {
                    Text(a.title).font(.headline)
                    Text(a.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("+\(a.xp) XP").font(.caption.monospacedDigit())
            }
            .opacity(done ? 1 : 0.6)
        }
    }
}
#endif
