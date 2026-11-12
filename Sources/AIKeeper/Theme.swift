import SwiftUI

/// Shared surface + type tokens. Neutral graphite surfaces; green is reserved for "space you can get back".
/// The brand palette. Ultramarine marks actions and "safe/finished" states, amber marks space you can reclaim,
/// violet marks merged pull requests, and everything neutral is gray. Green is deliberately not used.
enum Brand {
    static let accent = Color(red: 0.145, green: 0.271, blue: 0.961)    // #2545F5
    static let reclaim = Color(red: 0.961, green: 0.651, blue: 0.141)   // #F5A624
    static let merged = Color(red: 0.514, green: 0.380, blue: 0.929)    // #8361ED
    static let ink = Color(red: 0.063, green: 0.094, blue: 0.157)       // #101828
}

extension View {
    /// A raised surface with the brand's notched corners (the radius argument is kept so call sites read the same).
    func panel(_ radius: CGFloat = 12) -> some View {
        background(.background.secondary, in: NotchShape(cut: radius >= 10 ? 5 : 4))
            .overlay(NotchShape(cut: radius >= 10 ? 5 : 4).strokeBorder(.separator, lineWidth: 0.5))
    }
}

extension Font {
    /// Big numbers are set in the pixel face, the same as on the website.
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
