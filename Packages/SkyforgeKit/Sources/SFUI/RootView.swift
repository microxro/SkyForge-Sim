// SKYFORGE — Apache-2.0
/// SFUI: SwiftUI front end (product `SkyforgeUI`).
public enum SFUIInfo { public static let moduleVersion = "0.1.0" }

#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import MetalKit
import SFRender

/// Root view shown by the app. Items that are not implemented yet are labelled honestly.
public struct SkyforgeRootView: View {
    @State private var showingSky = false
    @State private var showingInstruments = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Renderer preview (sky)") { showingSky = true }
                    Button("Instruments demo (steam gauges and SF-1000 PFD)") { showingInstruments = true }
                    NavigationLink("Controls and bindings") { BindingsView() }
                } header: {
                    Text("Available")
                }
                Section {
                    Text("Quick Flight: not yet available")
                    Text("World map: not yet available")
                    Text("Settings: not yet available")
                } header: {
                    Text("Coming in later phases")
                }
                Section {
                    Text("SKYFORGE is free and open source (Apache-2.0).")
                        .font(.footnote)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("SKYFORGE")
            .sheet(isPresented: $showingInstruments) {
                InstrumentDemoView()
            }
            .sheet(isPresented: $showingSky) {
                SkyPreviewView()
                    .ignoresSafeArea()
            }
        }
    }
}

#if os(macOS)
struct SkyPreviewView: NSViewRepresentable {
    final class Coordinator { var renderer: SkyRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        context.coordinator.renderer = try? SkyRenderer(view: view)
        view.delegate = context.coordinator.renderer
        view.preferredFramesPerSecond = 60
        return view
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}
#else
struct SkyPreviewView: UIViewRepresentable {
    final class Coordinator { var renderer: SkyRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        context.coordinator.renderer = try? SkyRenderer(view: view)
        view.delegate = context.coordinator.renderer
        view.preferredFramesPerSecond = 60
        return view
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}
#endif
#endif
