// SKYFORGE — Apache-2.0
// Shared look for the home hub and menus: one glass section, one row label.
#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI

/// Corner radius used by every hub card, so menus read as one system.
enum SFHubStyle {
    static let cornerRadius: CGFloat = 22
}

/// A titled group of rows on one Liquid Glass card.
struct SFHubSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SFHubStyle.cornerRadius))
        }
    }
}

/// The content of one hub row: a symbol, a title, an optional subtitle and a disclosure chevron.
/// Used inside a Button or NavigationLink so the whole row is the tap target.
struct SFHubRowLabel: View {
    let title: String
    var subtitle: String?
    let symbol: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
#endif
