import SwiftUI

// Colors and small markers shared by every page: the agent palette, status tones, tags and dots.

enum AgentColor {
    static let claude = Color.dynamic(light: 0x2F45FF, dark: 0x6E7DFF)
    static let codex = Color.dynamic(light: 0x0EA5A0, dark: 0x2DD4BF)
    static let conductor = Color.dynamic(light: 0x7C3AED, dark: 0xB794F6)
    static let superset = Color.dynamic(light: 0xDB2777, dark: 0xF472B6)
    static let pi = Color.dynamic(light: 0x8E8E93, dark: 0xA1A1A6)
    static let good = Color.dynamic(light: 0x127A3E, dark: 0x4ADE80)
    static func of(_ name: String) -> Color {
        switch name.lowercased() {
        case "claude", "claude code": claude
        case "codex": codex
        case "conductor": conductor
        case "superset": superset
        default: pi
        }
    }
}

enum Tone { case blue, amber, red, violet, gray, green
    var fg: Color {
        switch self {
        case .blue: Brand.primaryText
        case .amber: Brand.reclaimText
        case .red: Brand.destructive
        case .violet: Brand.merged
        case .gray: Brand.mutedForeground
        case .green: AgentColor.good
        }
    }
    var bg: Color {
        switch self {
        case .blue: Brand.primaryTint
        case .amber: Brand.reclaimTint
        case .red: Brand.destructiveTint
        case .violet: Brand.merged.opacity(0.12)
        case .gray: Brand.muted
        case .green: AgentColor.good.opacity(0.14)
        }
    }
}

struct Tag: View {
    let text: String
    var tone: Tone = .gray
    var body: some View {
        Text(text).font(.brand(11, .medium)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tone.bg, in: Capsule()).foregroundStyle(tone.fg)
    }
}

struct Dot: View {
    let tone: Tone
    var body: some View { Circle().fill(tone == .gray ? Brand.mutedForeground.opacity(0.4) : tone.fg).frame(width: 7, height: 7) }
}
