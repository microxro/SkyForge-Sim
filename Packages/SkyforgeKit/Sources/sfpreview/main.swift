// SKYFORGE — Apache-2.0
// sfpreview: CPU preview renderer CLI (§8.6).
//   sfpreview --version
//   sfpreview icon <out.png> <size>
// Scene rendering (--scene ...) lands in P1.
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
fail("sfpreview: scene rendering is not yet available (P1 item, see PROGRESS.md)")
