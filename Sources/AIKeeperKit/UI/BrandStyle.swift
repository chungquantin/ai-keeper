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
            if !fonts.isEmpty { CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil); return }
        }
    }
}

extension Font {
    static let brandText = "Bricolage Grotesque", brandPixel = "Jersey 15", brandCode = "JetBrains Mono"

    /// Text in the brand face. Falls back to the system font if the files are missing.
    static func brand(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: size, weight: weight)   // the system font (SF Pro): calm, and it matches the redesign
    }
    static var bTitle2: Font { .brand(22, .semibold, relativeTo: .title2) }
    static var bTitle3: Font { .brand(18, .semibold, relativeTo: .title3) }
    static var bHeadline: Font { .brand(15, .semibold, relativeTo: .headline) }
    static var bBody: Font { .brand(13, .regular, relativeTo: .body) }
    static var bCallout: Font { .brand(13, .regular, relativeTo: .callout) }
    static var bCaption: Font { .brand(12, .regular, relativeTo: .caption) }
    static var bCaption2: Font { .brand(11, .medium, relativeTo: .caption2) }
    /// The pixel face, for numbers and small tags.
    static func pixel(_ size: CGFloat) -> Font { .system(size: size * 0.72, weight: .medium).monospacedDigit() }
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

extension Color {
    /// Like `dynamic`, with an alpha for each appearance (hairlines and tints).
    static func dynamic(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let h = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// The neutral surfaces and tints of the design system (tokens: background, card, popover, muted, border and their partners).
extension Brand {
    static let background = Color.dynamic(light: 0xF5F5F7, dark: 0x0E0E10)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x1A1A1C)
    static let popover = Color.dynamic(light: 0xFFFFFF, dark: 0x232326)
    static let muted = Color.dynamic(light: 0xEFEFF2, dark: 0x232326)
    static let mutedForeground = Color.dynamic(light: 0x66666B, dark: 0xA1A1A6)
    static let border = Color.dynamic(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let hover = Color.dynamic(light: 0x000000, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.07)
    static let primaryText = Color.dynamic(light: 0x2F45FF, dark: 0x8C99FF)
    static let primaryTint = Color.dynamic(light: 0x2F45FF, lightAlpha: 0.10, dark: 0x6E7DFF, darkAlpha: 0.20)
    static let reclaimText = Color.dynamic(light: 0xB25E00, dark: 0xFFB340)
    static let reclaimTint = Color.dynamic(light: 0xFF9F0A, lightAlpha: 0.16, dark: 0xFFB340, darkAlpha: 0.18)
    static let destructive = Color.dynamic(light: 0xD70015, dark: 0xFF6961)
    static let destructiveTint = Color.dynamic(light: 0xD70015, lightAlpha: 0.08, dark: 0xFF6961, darkAlpha: 0.18)
    static let surface = background
    /// The 1pt ring of `shadow-card`: lighter than a divider, so a card reads as lifted rather than outlined.
    static let edge = Color.dynamic(light: 0x191C21, lightAlpha: 0.10, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let liftNear = Color.dynamic(light: 0x000000, lightAlpha: 0.07, dark: 0x000000, darkAlpha: 0.45)
    static let liftFar = Color.dynamic(light: 0x191C21, lightAlpha: 0.02, dark: 0x000000, darkAlpha: 0.20)
    static let sidebar = Color.dynamic(light: 0xEDEDF0, dark: 0x18181A)
}

/// The primary button: `primary` (cobalt unless a tint is set), continuous corners, scales to 97% when pressed.
struct BrandProminentStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        let pad: (CGFloat, CGFloat) = size == .small || size == .mini ? (10, 4) : size == .large ? (20, 11) : (14, 7)
        let radius: CGFloat = size == .small || size == .mini ? 6 : size == .large ? 12 : 10
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .font(.brand(size == .large ? 14.5 : 13, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, pad.0).padding(.vertical, pad.1)
            .background(shape.fill(.tint))
            .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.16 : 0)))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(shape)
    }
}
extension ButtonStyle where Self == BrandProminentStyle { static var brandProminent: BrandProminentStyle { BrandProminentStyle() } }

/// The outline button (`btn-outline`): card surface, a faint ring, 8pt continuous corners. For the secondary action on a row.
struct BrandOutlineStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        let small = size == .small || size == .mini, large = size == .large
        let shape = RoundedRectangle(cornerRadius: large ? 12 : small ? 8 : 9, style: .continuous)
        configuration.label
            .font(.brand(large ? 14 : small ? 12 : 13, .medium)).foregroundStyle(Color.primary)
            .padding(.horizontal, large ? 18 : small ? 10 : 12).frame(height: large ? 40 : small ? 26 : 28)
            .background(Brand.card, in: shape)
            .overlay(shape.strokeBorder(Brand.border, lineWidth: 1))
            .overlay(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(shape)
    }
}
extension ButtonStyle where Self == BrandOutlineStyle { static var brandOutline: BrandOutlineStyle { BrandOutlineStyle() } }

/// A meter made of squares, like the gauges on the website: filled in the tint colour, the rest dim.
struct PixelMeter: View {
    var value: Double
    var tint: Color = Brand.accent
    var height: CGFloat = 8
    /// Paint the last filled square amber: the budget meter's "nearly there" mark.
    var warnTail = false
    /// A fixed count of wide segments that share the width (the budget meter). Nil keeps small squares.
    var segments: Int? = nil
    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = segments == nil ? 2 : 3
            let n = segments ?? max(1, Int((size.width + gap) / (height * 0.9 + gap)))
            let cell = segments == nil ? height * 0.9 : (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let filled = Int((min(max(value, 0), 1) * Double(n)).rounded(value > 0 ? .up : .down))
            for i in 0..<n {
                ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * (cell + gap), y: (size.height - height) / 2, width: cell, height: height), cornerRadius: segments == nil ? 2 : 3),
                         with: .color(i < filled ? (warnTail && i == filled - 1 ? Brand.reclaim : tint) : Color.primary.opacity(0.12)))
            }
        }
        .frame(height: height)
        .accessibilityElement().accessibilityValue("\(Int(value * 100)) percent")
    }
}
