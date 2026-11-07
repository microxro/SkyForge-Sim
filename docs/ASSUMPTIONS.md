# Assumptions

1. The macOS app ignores iOS-only Info.plist keys (`LSRequiresIPhoneOS`, `UIRequiredDeviceCapabilities`, `UISupportedInterfaceOrientations*`) in a native multiplatform target. Verify on Mac day.
2. `XCSwiftPackageProductDependency` for a local package may carry `package = <XCLocalSwiftPackageReference>`; Xcode accepts this. Verify in CI.
3. US government data (FAA CIFP) is presumed public domain under 17 U.S.C. §105 (P4).
4. Geoid ≈ ellipsoid in P1 (±100 m error documented) until EGM96 terms are verified.
5. The swift-crypto version range 3.0.0..<5.0.0 resolves to an Apache-2.0 release on both Linux and Apple platforms.
