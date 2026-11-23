// SKYFORGE — Apache-2.0
// The on-screen card for the first-flight tutorial. The lesson logic lives in SFTutorial; this only draws it.
#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import SFTutorial

struct TutorialCard: View {
    let engine: TutorialEngine
    let gotIt: () -> Void
    let skip: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lesson = engine.current {
                Text("Lesson \(engine.index + 1) of \(engine.lessons.count): \(lesson.title)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Text(lesson.prompt)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = engine.currentHint {
                    Text("Hint: \(hint)").font(.caption).foregroundStyle(.yellow)
                }
                if let warning = engine.recovery {
                    Text(warning.text).font(.callout.bold()).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if lesson.requiresConfirm {
                        Button("Got it", action: gotIt).buttonStyle(.borderedProminent)
                    }
                    if engine.canSkip {
                        Button("Skip this lesson", action: skip).buttonStyle(.bordered)
                    }
                    Spacer()
                    ProgressView(value: engine.fraction).frame(width: 80)
                }
            } else {
                Text("Tutorial complete. You have flown a full circuit.")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                Text("Flight school, with licence lessons, comes in a later update.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                Button("Done", action: finish).buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
#endif
