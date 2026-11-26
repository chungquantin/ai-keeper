import SwiftUI

/// Shared surface + type tokens. Neutral graphite surfaces; green is reserved for "space you can get back".
/// The brand palette. Ultramarine marks actions and "safe/finished" states, amber marks space you can reclaim,
/// violet marks merged pull requests, and everything neutral is gray. Green is deliberately not used.
enum Brand {
    /// The one action colour (design system: `primary`). Cobalt by day, a lighter cobalt at night so white text still reads on it.
    static let accent = Color.dynamic(light: 0x2F45FF, dark: 0x4A5CFF)
    /// Space you can get back (`reclaim`). A fill or glyph; for amber text use `reclaimText`.
    static let reclaim = Color.dynamic(light: 0xFF9F0A, dark: 0xFFB340)
    /// A merged pull request (`merged`).
    static let merged = Color.dynamic(light: 0x7C3AED, dark: 0xB794F6)
    static let ink = Color(red: 0.063, green: 0.094, blue: 0.157)       // #101828
}

extension View {
    /// A card, as `shadow-card` draws it: the `card` surface, continuous corners, a faint 1pt ring, a tight 1pt shadow and a soft lift below.
    /// `raised` adds more lift for the one card that matters.
    func panel(_ radius: CGFloat = 14, raised: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Brand.card, in: shape)
            .overlay(shape.strokeBorder(Brand.edge, lineWidth: 1))
            .shadow(color: Brand.liftNear, radius: 1, y: 1)
            .shadow(color: Brand.liftFar.opacity(raised ? 1.6 : 1), radius: raised ? 12 : 8, y: raised ? 8 : 5)
    }
}

extension Font {
    /// Big numbers are set large in the system font, medium weight, tabular digits.
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        pixel(size * 1.3)
    }
}

extension Int64 {
    /// ("70,05", "GB") so the unit can be set smaller than the number.
    var byteParts: (number: String, unit: String) {
        let s = bytesString
        guard let i = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }
}

/// Status marker: a colored dot with a plain label. Quieter than a tinted capsule and never truncates.
struct Pill: View {
    let text: String
    let color: Color
    /// In a table column the label shortens with an ellipsis (and the full text is the tooltip) instead of spilling into the next column.
    var truncates = false
    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 6, height: 6)   // a pixel, not a dot
            Text(text).font(.bCaption).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(color == .red ? Color.red : Color.secondary)
        }
        .modifier(PillFit(truncates: truncates, text: text))
    }
}

private struct PillFit: ViewModifier {
    let truncates: Bool
    let text: String
    func body(content: Content) -> some View {
        if truncates { content.help(text) } else { content.fixedSize() }
    }
}

/// One divided strip of headline numbers instead of a row of identical cards.
struct StatStrip: View {
    struct Item { let title: String; let value: String; var note: String? }
    let items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    Text(items[i].title).font(.bCallout).foregroundStyle(.secondary)
                    Text(items[i].value).font(.figure(30)).monospacedDigit()
                    Text(items[i].note ?? " ").font(.bCaption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 14)
                if i < items.count - 1 { Divider().padding(.vertical, 12) }
            }
        }
        .panel()
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(text).font(.bHeadline)
            Spacer()
            if let trailing { Text(trailing).font(.bCallout).foregroundStyle(.secondary) }
        }
    }
}

/// Row-sized button with a hover and press state, so clickable rows feel clickable without extra chrome.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverRow(configuration: configuration) }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.05 : 0))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}
