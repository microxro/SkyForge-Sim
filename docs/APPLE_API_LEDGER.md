# Apple API ledger

Status "compiled (iOS Sim, Xcode 26.6)": the symbol compiled in CI run 42420061164 for the iOS Simulator SDK 26.5. Runtime behaviour is still unverified until a device or simulator run.

Every Apple API used. Unverified entries are the first suspects for Mac-day compile errors.

| Framework | Symbol | Min OS | File | Docs | Status |
|---|---|---|---|---|---|
| Metal | `MTLCreateSystemDefaultDevice()` | iOS 8 / macOS 10.11 | SFRender/SkyRenderer.swift, SFUI/RootView.swift | https://developer.apple.com/documentation/metal/mtlcreatesystemdefaultdevice() | compiled (iOS Sim, Xcode 26.6) |
| Metal | `MTLDevice.makeCommandQueue()` | iOS 8 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtldevice/makecommandqueue() | compiled (iOS Sim, Xcode 26.6) |
| Metal | `MTLDevice.makeLibrary(source:options:)` (throwing) | iOS 8 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtldevice/makelibrary(source:options:) | compiled (iOS Sim, Xcode 26.6) |
| Metal | `MTLLibrary.makeFunction(name:)` | iOS 8 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtllibrary/makefunction(name:) | compiled (iOS Sim, Xcode 26.6) |
| Metal | `MTLRenderPipelineDescriptor`, `makeRenderPipelineState(descriptor:)` | iOS 8 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtlrenderpipelinedescriptor | compiled (iOS Sim, Xcode 26.6) |
| Metal | `MTLRenderCommandEncoder.setFragmentBytes(_:length:index:)`, `drawPrimitives(type:vertexStart:vertexCount:)` | iOS 8.3 / macOS 10.11 | SkyRenderer.swift | https://developer.apple.com/documentation/metal/mtlrendercommandencoder | compiled (iOS Sim, Xcode 26.6) |
| Metal | `MTLDevice.supportsFamily(_:)`, `.apple7`, `.apple9` | iOS 13 / macOS 10.15 (apple9: iOS 17 / macOS 14) | SFPlatform/DeviceTier.swift | https://developer.apple.com/documentation/metal/mtldevice/supportsfamily(_:) | compiled (iOS Sim, Xcode 26.6) |
| MetalKit | `MTKView`, `MTKViewDelegate`, `currentRenderPassDescriptor`, `currentDrawable`, `drawableSize`, `clearDepth`, `preferredFramesPerSecond` | iOS 9 / macOS 10.11 | SkyRenderer.swift, RootView.swift | https://developer.apple.com/documentation/metalkit/mtkview | compiled (iOS Sim, Xcode 26.6) |
| QuartzCore | `CACurrentMediaTime()` (via MetalKit import) | iOS 2 / macOS 10.5 | SkyRenderer.swift | https://developer.apple.com/documentation/quartzcore/1395996-cacurrentmediatime | unverified (import path) |
| SwiftUI | `NavigationStack`, `List`, `Section(content:header:)`, `.sheet(isPresented:)`, `NSViewRepresentable`, `UIViewRepresentable` | iOS 16 / macOS 13 | SFUI/RootView.swift | https://developer.apple.com/documentation/swiftui | compiled (iOS Sim, Xcode 26.6) |
| Foundation | `ProcessInfo.physicalMemory` | all | DeviceTier.swift | https://developer.apple.com/documentation/foundation/processinfo/physicalmemory | compiled (iOS Sim, Xcode 26.6) |
| GameController | `GCController.controllers()`, `extendedGamepad`, `leftThumbstick.xAxis.value`, `rightTrigger.value`, `buttonA.isPressed` | iOS 14 / macOS 11 | SFPlatform/GameControllerInput.swift | https://developer.apple.com/documentation/gamecontroller/gcextendedgamepad | unverified (pending CI) |
| GameController | `GCKeyboard.coalesced`, `keyboardInput.button(forKeyCode:)`, `GCKeyCode.keyW` etc. | iOS 14 / macOS 11 | SFPlatform/GameControllerInput.swift | https://developer.apple.com/documentation/gamecontroller/gckeyboard | unverified (pending CI) |
