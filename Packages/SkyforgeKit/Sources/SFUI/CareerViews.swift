// SKYFORGE — Apache-2.0
// Career hub: profile, hangar, achievements and campaigns. Logic lives in SFCareer (tested on Linux);
// these views only present a CareerState and report purchases back through `onChange`.
#if canImport(SwiftUI)
import Foundation
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
            AirlineView(career: $career, onChange: onChange)
                .tabItem { Label("Airline", systemImage: "airplane.departure") }
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

/// Today's scheduled airline legs. Accepting one makes it the active job; flying it is handled by the flight.
struct AirlineView: View {
    @Binding var career: CareerState
    var onChange: () -> Void
    @State private var message: String?

    var body: some View {
        let routes = AirlineNetwork.schedule(for: career, dayIndex: Int(Date().timeIntervalSince1970 / 86_400))
        List {
            Section {
                Text("\(career.airline.rank.title) · \(career.airline.legsFlown) legs · reputation \(Int(career.airline.reputation))")
                    .font(.callout)
                if let route = career.activeAirlineRoute {
                    Label("Active: \(route.origin.icao) to \(route.destination.icao)", systemImage: "airplane")
                }
                if let message { Text(message).font(.callout) }
            }
            Section("Today's legs from \(AirlineNetwork.hub.icao)") {
                if routes.isEmpty { Text("No legs today.").foregroundStyle(.secondary) }
                ForEach(routes) { route in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(route.origin.icao) to \(route.destination.icao)").font(.headline)
                            Spacer()
                            Button("Accept") { accept(route) }
                                .buttonStyle(.borderedProminent)
                                .disabled(career.activeAirlineRoute != nil || career.activeJob != nil)
                        }
                        Text("\(route.passengers) passengers · \(Int(route.distanceKm)) km · \(route.basePay) credits · min \(route.minimumRank.title)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Accepts the leg with the first aircraft the pilot can use that the leg allows.
    func accept(_ route: AirlineRoute) {
        let pilotRank = career.rank
        for a in Economy.catalog where career.canUse(aircraftID: a.id) {
            if case .success = career.accept(airline: route, aircraft: a, pilotRank: pilotRank) {
                message = "Accepted \(route.destination.icao) in the \(a.name)"
                onChange()
                return
            }
        }
        message = "No aircraft you can fly fits this leg yet"
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
