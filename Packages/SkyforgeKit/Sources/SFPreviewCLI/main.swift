// SKYFORGE — Apache-2.0
// sfpreview: CPU preview renderer CLI (§8.6).
//   sfpreview --version
//   sfpreview icon <out.png> <size>
//   sfpreview --scene <name> [--time <preset>] [--seed <n>] [--width W --height H] [--ss N] --out <file.png>
import Foundation
import SFPreview

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--version" {
    print("sfpreview \(SFPreviewInfo.moduleVersion)")
    exit(0)
}
if args.first == "icon" {
    guard args.count == 3, let size = Int(args[2]), size >= 16, size <= 2048 else { fail("usage: sfpreview icon <out.png> <size>") }
    let px = IconRenderer.render(size: size)
    do { try PNGEncoder.encodeRGB(width: size, height: size, rgb: px).write(to: URL(fileURLWithPath: args[1])) }
    catch { fail("sfpreview: cannot write \(args[1]): \(error)", code: 1) }
    exit(0)
}

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let sceneName = value("--scene") else {
    fail("usage: sfpreview --scene <\(PreviewScene.allCases.map(\.rawValue).joined(separator: "|"))> [--time <\(TimePreset.allCases.map(\.rawValue).joined(separator: "|"))>] [--seed n] --out file.png")
}
guard let scene = PreviewScene(rawValue: sceneName) else {
    fail("sfpreview: scene '\(sceneName)' is not available yet. Available: \(PreviewScene.allCases.map(\.rawValue).joined(separator: ", "))")
}
let time = value("--time").map { name -> TimePreset in
    guard let t = TimePreset(rawValue: name) else { fail("sfpreview: unknown time preset \(name)") }
    return t
}
let seed = value("--seed").flatMap(UInt64.init) ?? 1
let width = value("--width").flatMap(Int.init) ?? 1280
let height = value("--height").flatMap(Int.init) ?? 720
let ss = value("--ss").flatMap(Int.init) ?? 2
guard let out = value("--out") else { fail("sfpreview: --out <file.png> is required") }

let start = Date()
let (img, stats, counts) = PreviewScenes.render(scene, time: time, seed: seed, width: width, height: height, supersample: ss)
do { try img.png().write(to: URL(fileURLWithPath: out)) } catch { fail("sfpreview: cannot write \(out): \(error)", code: 1) }
let total = Date().timeIntervalSince(start)
print(String(format: "sfpreview: %@ %@ seed %llu -> %@ (%d tris; build %.1fs shadow %.1fs raster %.1fs shade %.1fs; total %.1fs) %@",
             scene.rawValue, (time ?? scene.defaultTime).rawValue, seed, out, stats.triangles,
             stats.buildSeconds, stats.shadowSeconds, stats.rasterSeconds, stats.shadeSeconds, total,
             counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")))
