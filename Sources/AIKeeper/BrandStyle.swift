import SwiftUI
import AppKit
import CoreText

// The AI Keeper look, shared with the website: Bricolage Grotesque for text, the Jersey pixel face for numbers and tags,
// JetBrains Mono for code, cobalt and navy surfaces, and corners cut in one pixel step.

enum BrandFonts {
    /// Registers the bundled fonts for this process. They ship in the app's Resources/Fonts; a development build finds assets/fonts above the binary.
    static func register() {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Fonts")) }
        var u = URL(fileURLWithPath: Runtime.executable).deletingLastPathComponent()
        for _ in 0..<7 { dirs.append(u.appendingPathComponent("assets/fonts")); u.deleteLastPathComponent() }
        for d in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            let fonts = files.filter { $0.pathExtension.lowercased() == "ttf" }
            if !fonts.isEmpty { CTFontManagerRegisterFontsForURLs(fonts as CFArray, .process, nil); return }
        }
    }
}

extension Font {
    static let brandText = "Bricolage Grotesque", brandPixel = "Jersey 15", brandCode = "JetBrains Mono"

    /// Text in the brand face. Falls back to the system font if the files are missing.
    static func brand(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(brandText, size: size, relativeTo: style).weight(weight)
    }
    static var bTitle2: Font { .brand(21, .bold, relativeTo: .title2) }
    static var bTitle3: Font { .brand(17, .semibold, relativeTo: .title3) }
    static var bHeadline: Font { .brand(14.5, .semibold, relativeTo: .headline) }
    static var bBody: Font { .brand(13.5, .regular, relativeTo: .body) }
    static var bCallout: Font { .brand(13, .regular, relativeTo: .callout) }
    static var bCaption: Font { .brand(11.5, .regular, relativeTo: .caption) }
    static var bCaption2: Font { .brand(10.5, .regular, relativeTo: .caption2) }
    /// The pixel face, for numbers and small tags.
    static func pixel(_ size: CGFloat) -> Font { .custom(brandPixel, size: size) }
    static func code(_ size: CGFloat) -> Font { .custom(brandCode, size: size) }
}

extension Color {
    /// A colour that follows light and dark appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let h = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
        })
    }
}

extension Brand {
    static let night = Color(px: 0x0F1760)
    static let paper = Color(px: 0xF4F6FF)
    static let mist = Color(px: 0xDFE5FF)
    /// Surfaces follow the system's own colours.
    static let surface = Color(nsColor: .windowBackgroundColor)
}

/// A rectangle with its corners cut in one pixel step: the shape every panel and button uses on the website.
struct NotchShape: InsettableShape {
    var cut: CGFloat = 4
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset), c = min(cut, r.width / 4, r.height / 4)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + c))
        for pt in [(c, c), (c, 0), (r.width - c, 0), (r.width - c, c), (r.width, c), (r.width, r.height - c), (r.width - c, r.height - c),
                   (r.width - c, r.height), (c, r.height), (c, r.height - c), (0, r.height - c)] {
            p.addLine(to: CGPoint(x: r.minX + pt.0, y: r.minY + pt.1))
        }
        p.closeSubpath()
        return p
    }
    func inset(by amount: CGFloat) -> NotchShape { var s = self; s.inset += amount; return s }
}

/// The primary button: tint-coloured (cobalt unless a tint is set) with notched corners.
struct BrandProminentStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        let pad: (CGFloat, CGFloat) = size == .small || size == .mini ? (10, 4) : size == .large ? (18, 9) : (14, 6)
        configuration.label
            .font(.brand(size == .large ? 14.5 : 13, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, pad.0).padding(.vertical, pad.1)
            .background(NotchShape(cut: size == .small || size == .mini ? 3 : 4).fill(.tint))
            .overlay(NotchShape(cut: size == .small || size == .mini ? 3 : 4).fill(Color.black.opacity(configuration.isPressed ? 0.22 : 0)))
            .opacity(enabled ? 1 : 0.45)
            .offset(y: configuration.isPressed ? 1 : 0)
            .contentShape(NotchShape())
    }
}
extension ButtonStyle where Self == BrandProminentStyle { static var brandProminent: BrandProminentStyle { BrandProminentStyle() } }

/// A meter made of squares, like the gauges on the website: filled in the tint colour, the rest dim.
struct PixelMeter: View {
    var value: Double
    var tint: Color = Brand.accent
    var height: CGFloat = 8
    var body: some View {
        Canvas { ctx, size in
            let cell = height * 0.9, gap: CGFloat = 2, n = max(1, Int((size.width + gap) / (cell + gap)))
            let filled = Int((min(max(value, 0), 1) * Double(n)).rounded(value > 0 ? .up : .down))
            for i in 0..<n {
                ctx.fill(Path(CGRect(x: CGFloat(i) * (cell + gap), y: (size.height - height) / 2, width: cell, height: height)),
                         with: .color(i < filled ? tint : Color.primary.opacity(0.12)))
            }
        }
        .frame(height: height)
        .accessibilityElement().accessibilityValue("\(Int(value * 100)) percent")
    }
}
