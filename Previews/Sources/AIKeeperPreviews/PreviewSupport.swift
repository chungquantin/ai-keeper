import SwiftUI
@testable import AIKeeperKit

// Previews are the app's component catalog: open Previews/Package.swift in Xcode and use the canvas
// (Editor > Canvas). Every preview runs on the same invented demo data as `AIKEEPER_DEMO=1`, so nothing here reads this Mac.

@MainActor
enum PreviewKit {
    /// A store filled with demo workspaces, agents, sessions and spend.
    static let store: Store = {
        setenv("AIKEEPER_DEMO", "1", 1)   // before the store reads its settings, so nothing is written
        let s = Store()
        s.loadDemo()
        return s
    }()
    static func nav(_ area: Area = .today, _ tab: AIKeeperKit.Tab? = nil) -> NavState {
        let n = NavState(); n.open(area, tab); return n
    }
}

extension View {
    /// Gives a view what the running app gives it: the demo store, navigation, the cobalt tint and the body font.
    @MainActor func previewEnv(_ area: Area = .today, _ tab: AIKeeperKit.Tab? = nil) -> some View {
        environment(PreviewKit.store).environment(PreviewKit.store.basket).environment(PreviewKit.nav(area, tab)).tint(Brand.accent).font(.bBody)
    }
    /// A page sized like the content column of the app at its usual width.
    func previewPage(width: CGFloat = 1120, height: CGFloat = 780) -> some View {
        frame(width: width, height: height).background(Brand.background)
    }
}

/// Stable pseudo-random numbers so chart previews look the same every time.
enum PreviewData {
    static func seeded(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }
    static func series(_ n: Int, _ k: Int, base: Double = 0.5, spread: Double = 0.35, drift: Double = 0) -> [Double] {
        (0..<n).map { max(0.04, min(1, base + drift * Double($0) + (seeded($0, k) - 0.5) * spread * 2)) }
    }
}
