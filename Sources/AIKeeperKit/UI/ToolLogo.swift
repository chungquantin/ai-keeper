import SwiftUI
import AppKit

/// The real logos of the tools AI Keeper works with. One-colour marks are tinted to match the surrounding text (light, dark and
/// the selected sidebar row); full colour app icons are shown as they are. Anything without a logo falls back to an SF Symbol.
enum ToolLogo {
    private nonisolated(unsafe) static var cache: [String: (image: NSImage, template: Bool)] = [:]

    static func image(_ id: String) -> (image: NSImage, template: Bool)? {
        if let hit = cache[id] { return hit }
        guard let entry = ToolLogoData.all[id], let data = Data(base64Encoded: entry.png), let img = NSImage(data: data) else { return nil }
        img.isTemplate = entry.template
        cache[id] = (img, entry.template)
        return cache[id]
    }
}

extension Source {
    /// The id of this tool's logo, if it has one.
    var logoID: String? {
        switch self {
        case .claude: "claude"
        case .conductor: "conductor"
        case .git: "git"
        case .codex: "codex"
        case .superset: "superset"
        case .pi: "pi"
        case .zcode: "zcode"
        case .dev: nil
        }
    }
}

struct ToolIcon: View {
    let id: String?
    var fallback = "square.dashed"
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let id, let logo = ToolLogo.image(id) {
                if logo.template {
                    Image(nsImage: logo.image).renderingMode(.template).resizable().scaledToFit().padding(size * 0.06)
                } else {
                    Image(nsImage: logo.image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                }
            } else {
                Image(systemName: fallback).resizable().scaledToFit().padding(size * 0.1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The lab behind a model, read from its name, so a model table can show the maker's mark.
enum ModelLogo {
    static func id(for model: String) -> String? {
        let m = model.lowercased()
        let table: [(String, String)] = [("claude", "claude"), ("opus", "claude"), ("sonnet", "claude"), ("haiku", "claude"), ("gpt", "openai"), ("codex", "openai"), ("o1", "openai"), ("o3", "openai"), ("o4", "openai"),
                                         ("gemini", "gemini"), ("gemma", "gemini"), ("llama", "meta"), ("mistral", "mistral"), ("codestral", "mistral"), ("deepseek", "deepseek"), ("qwen", "qwen"),
                                         ("grok", "grok"), ("kimi", "kimi"), ("moonshot", "kimi"), ("glm", "zhipu"), ("minimax", "minimax"), ("ollama", "ollama")]
        return table.first { m.contains($0.0) }?.1
    }
}
