# Apple API ledger

Every Apple API used. Unverified entries are the first suspects for Mac-day compile errors.

| Framework | Symbol | Min OS | File | Docs | Status |
|---|---|---|---|---|---|
| Metal | `MTLCreateSystemDefaultDevice()` | iOS 8 / macOS 10.11 | SFRender/SkyRenderer.swift, SFUI/RootView.swift | https://developer.apple.com/documentation/metal/mtlcreatesystemdefaultdevice() | unverified |
| Metal | `MTLDevice.makeCommandQueue()` | iOS 8 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtldevice/makecommandqueue() | unverified |
| Metal | `MTLDevice.makeLibrary(source:options:)` (throwing) | iOS 8 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtldevice/makelibrary(source:options:) | unverified |
| Metal | `MTLLibrary.makeFunction(name:)` | iOS 8 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtllibrary/makefunction(name:) | unverified |
| Metal | `MTLRenderPipelineDescriptor`, `makeRenderPipelineState(descriptor:)` | iOS 8 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtlrenderpipelinedescriptor | unverified |
| Metal | `MTLRenderCommandEncoder.setFragmentBytes(_:length:index:)`, `drawPrimitives(type:vertexStart:vertexCount:)` | iOS 8.3 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtlrendercommandencoder | unverified |
| Metal | `MTLDevice.supportsFamily(_:)`, `.apple7`, `.apple9` | iOS 13 / macOS 10.15 (apple9: iOS 17 / macOS 14) | SFPlatform/DeviceTier.swift | https://developer.apple.com/documentation/metal/mtldevice/supportsfamily(_:) | unverified |
| MetalKit | `MTKView`, `MTKViewDelegate`, `currentRenderPassDescriptor`, `currentDrawable`, `drawableSize`, `clearDepth`, `preferredFramesPerSecond` | iOS 9 / macOS 10.11 | SkyRenderer.swift, RootView.swift | https://developer.apple.com/documentation/metalkit/mtkview | unverified |
| QuartzCore | `CACurrentMediaTime()` (via MetalKit import) | iOS 2 / macOS 10.5 | SkyRenderer.swift | https://developer.apple.com/documentation/quartzcore/1395996-cacurrentmediatime | unverified (import path) |
| SwiftUI | `NavigationStack`, `List`, `Section(content:header:)`, `.sheet(isPresented:)`, `NSViewRepresentable`, `UIViewRepresentable` | iOS 16 / macOS 13 | SFUI/RootView.swift | https://developer.apple.com/documentation/swiftui | unverified |
| Foundation | `ProcessInfo.physicalMemory` | all | DeviceTier.swift | https://developer.apple.com/documentation/foundation/processinfo/physicalmemory | unverified |
