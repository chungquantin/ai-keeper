import SwiftUI

/// Shared surface + type tokens. Neutral graphite surfaces; green is reserved for "space you can get back".
extension View {
    func panel(_ radius: CGFloat = 12) -> some View {
        background(.background.secondary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

extension Font {
    /// Numerals set in New York: figures read like a ledger rather than a dashboard.
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
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
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
                .foregroundStyle(color == .red ? Color.red : Color.secondary)
        }
        .fixedSize()
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
                    Text(items[i].title).font(.callout).foregroundStyle(.secondary)
                    Text(items[i].value).font(.figure(30)).monospacedDigit()
                    Text(items[i].note ?? " ").font(.caption).foregroundStyle(.tertiary)
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
            Text(text).font(.headline)
            Spacer()
            if let trailing { Text(trailing).font(.callout).foregroundStyle(.secondary) }
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
