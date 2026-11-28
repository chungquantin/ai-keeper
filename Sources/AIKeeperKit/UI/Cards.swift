import SwiftUI

// Cards, page scaffolding, key numbers and list rows.

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).panel()
    }
}

struct CardTitle: View {
    let title: String
    var note: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.bHeadline)
            Spacer()
            if let note { Text(note).font(.bCaption).foregroundStyle(.secondary) }
        }
    }
}

/// A scrolling page with the standard margins and, optionally, the page header from the design:
/// the page's name, one line saying what it is for, and its main action. It also tells its children how wide it is.
struct Page<Content: View>: View {
    var title: String?
    var subtitle: String?
    var action: String?
    var sample = false
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(.horizontal, geo.size.width < 760 ? 16 : 28).padding(.vertical, 16)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.pageWidth, geo.size.width)
        }
    }
}

/// A single line of advice, set on a muted ground.
struct Note: View {
    let text: String
    var body: some View {
        Text(text).font(.bCaption).foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A row in a list card: leading marker, two lines of text, optional trailing pieces.
struct ListRow<Lead: View, Trail: View>: View {
    let title: String
    var subtitle: String?
    var selected = false
    @ViewBuilder var lead: Lead
    @ViewBuilder var trail: Trail
    var body: some View {
        HStack(spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.bBody.weight(.medium)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.bCaption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trail
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(selected ? Brand.primaryTint : .clear)
    }
}

struct KPI: View {
    let title: String
    let value: String
    var prior: String?
    var delta: String?
    var good: Bool?
    var spark: [Double]?
    var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                Text(title).font(.bCaption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                if let delta { Delta(text: delta, good: good).fixedSize() }
            }
            Text(value).font(.brand(26, .semibold)).kerning(-0.6).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(prior ?? " ").font(.bCaption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            if let spark { Spark(values: spark, color: good == false ? Brand.destructive : (good == true ? AgentColor.good : Brand.accent)).frame(height: 30).padding(.top, 6) }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, spark == nil ? 14 : 0)
        .frame(maxWidth: .infinity, minHeight: spark == nil ? 92 : 124, maxHeight: .infinity, alignment: .topLeading).clipped()
        .panel()
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent, lineWidth: selected ? 2 : 0))
    }
}

struct KPIRow: View {
    let items: [KPI]
    /// Wraps to a second line when the window is narrow, so a tile never has to truncate its number.
    var body: some View {
        // One row when every tile fits at its minimum width, so no empty slot is left at the end; a wrapping grid otherwise.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(items.indices, id: \.self) { items[$0].frame(minWidth: 150) } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) { ForEach(items.indices, id: \.self) { items[$0] } }
        }
    }
}

struct Delta: View {
    let text: String
    var good: Bool?
    var body: some View {
        let tone: Tone = good == nil ? .gray : (good! ? .green : .red)
        Text(text).font(.brand(11, .semibold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(tone.bg, in: Capsule()).foregroundStyle(tone.fg)
    }
}
