// SKYFORGE — Apache-2.0
// Aircraft and mission selection: pick an aircraft, then free flight or a mission it may fly.
#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import SFGameplay
import SFGameplayUI

struct GameplayMenuView: View {
    let onStart: (PlaneSpec, MissionDefinition?) -> Void
    @State private var progress = ProgressStore(url: ProgressStore.defaultURL).load()
    @State private var aircraftID = ProgressStore(url: ProgressStore.defaultURL).load().selectedAircraftID
    @State private var tab = 0
    @Environment(\.dismiss) private var dismiss

    private var aircraft: PlaneSpec { AircraftCatalog.spec(id: aircraftID) ?? AircraftCatalog.sf1Trainer }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                Text("Aircraft").tag(0)
                Text("Missions").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            if tab == 0 {
                AircraftPickerView(progress: progress, selectedID: $aircraftID)
                Button("Free flight in the \(aircraft.name)") { onStart(aircraft, nil); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!progress.isUnlocked(aircraft))
                    .padding()
            } else {
                MissionListView(progress: progress, aircraftID: aircraftID) { mission, craft in
                    onStart(craft, mission); dismiss()
                }
            }
        }
        .navigationTitle("Aircraft and missions")
        .onAppear { progress = ProgressStore(url: ProgressStore.defaultURL).load() }
        .onChange(of: aircraftID) { _, id in
            // Remember the choice. Losing this preference is harmless, so a failed write is not reported.
            var p = ProgressStore(url: ProgressStore.defaultURL).load()
            p.selectedAircraftID = id
            try? ProgressStore(url: ProgressStore.defaultURL).save(p)
        }
    }
}
#endif
