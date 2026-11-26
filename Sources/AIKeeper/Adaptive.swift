import SwiftUI

// Layout that follows the window. The app's minimum width is 1060 and people run it at a third of a 4K display or full screen,
// so side-by-side cards stack, side panels step aside, and chips wrap instead of truncating.

private struct PageWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 1000 }
extension EnvironmentValues {
    /// The width the current page has to work with, set by `Page`.
    var pageWidth: CGFloat { get { self[PageWidthKey.self] } set { self[PageWidthKey.self] = newValue } }
}

/// Children sit side by side while each flexible one still has `minChild` points, and stack when they do not.
/// A child with a fixed width (`.frame(width:)`) keeps it.
struct AdaptiveRow: Layout {
    var spacing: CGFloat = 14
    var minChild: CGFloat = 300

    private func fixedWidth(_ s: LayoutSubview) -> CGFloat? {
        let a = s.sizeThatFits(ProposedViewSize(width: 10, height: nil)).width
        let b = s.sizeThatFits(ProposedViewSize(width: 5000, height: nil)).width
        return abs(a - b) < 0.5 ? a : nil
    }
    private func widths(_ total: CGFloat, _ subs: Subviews) -> [CGFloat]? {
        let fixed = subs.map(fixedWidth)
        let flexCount = fixed.filter { $0 == nil }.count
        let fixedSum = fixed.compactMap { $0 }.reduce(0, +)
        let gaps = spacing * CGFloat(max(subs.count - 1, 0))
        guard flexCount == 0 || total - fixedSum - gaps >= CGFloat(flexCount) * minChild else { return nil }
        let each = flexCount == 0 ? 0 : (total - fixedSum - gaps) / CGFloat(flexCount)
        return fixed.map { $0 ?? each }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 900
        if let cols = widths(w, subviews) {
            let h = zip(subviews, cols).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
            return CGSize(width: w, height: h)
        }
        let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let cols = widths(bounds.width, subviews) {
            var x = bounds.minX
            for (s, w) in zip(subviews, cols) {
                s.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: nil))
                x += w + spacing
            }
        } else {
            var y = bounds.minY
            for s in subviews {
                let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                s.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
        }
    }
}

/// Items in a row that wraps onto the next line when it runs out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, usedW: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += sz.width + spacing; lineH = max(lineH, sz.height); usedW = max(usedW, x - spacing)
        }
        return CGSize(width: proposal.width ?? usedW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += sz.width + spacing; lineH = max(lineH, sz.height)
        }
    }
}
