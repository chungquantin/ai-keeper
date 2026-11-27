import SwiftUI

// Segmented control and filter menu.

/// The segmented control from the design: a muted track, and the chosen segment raised in white. Never cobalt, so it does not compete with data.
struct Seg<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    init(_ options: [(String, T)], selection: Binding<T>) { self.options = options; _selection = selection }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].1 == selection
                Button { selection = options[i].1 } label: {
                    Text(options[i].0).font(.brand(12, .medium)).foregroundStyle(on ? Color.primary : Brand.mutedForeground)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.card)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.edge))
                                .shadow(color: Brand.liftNear, radius: 1, y: 1) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2).background(Brand.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).fixedSize()
    }
}

/// A filter pill that opens a menu: "Last 30 days", "All agents".
struct PillMenu<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    init(_ options: [(String, T)], selection: Binding<T>) { self.options = options; _selection = selection }
    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in Button(options[i].0) { selection = options[i].1 } }
        } label: {
            Text(options.first { $0.1 == selection }?.0 ?? "").font(.brand(12, .medium)).foregroundStyle(Color.primary)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.border))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
