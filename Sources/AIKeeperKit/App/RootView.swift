import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @State private var showSplash = !(Screenshots.outDir != nil || Recording.outDir != nil || Soak.seconds != nil || Demo.enabled
                                      || ProcessInfo.processInfo.environment["AIKEEPER_NOSPLASH"] != nil)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            // A flat pane with a hairline, as designed: not the system's floating glass sidebar.
            SidebarView()
                .frame(width: 232)
                .background(Brand.sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(Brand.border).frame(width: 1) }
            ZStack {
                AreaView(area: nav.area)
            }
            .background(Brand.background)
            .id(nav.area)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: nav.area)
            // Inside the content column, not over the sidebar or toolbar.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let a = store.alert {
                    AlertBanner(alert: a, go: { nav.go($0) })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: store.alert?.id)
        }
        .ignoresSafeArea(.container, edges: .top)   // the header bar and the sidebar run to the top of the window
        .onChange(of: store.requestedDestination) { _, s in if let s { nav.go(s); store.requestedDestination = nil } }
        .overlay {
            if showSplash { SplashView(onSkip: { dismissSplash() }).environment(store).transition(.opacity) }
        }
        .task {
            guard showSplash else { return }
            // Long enough to see the robots at work, and until the first scan has something to show (never more than six seconds).
            let began = Date()
            try? await Task.sleep(for: .seconds(2.6))
            while store.isScanning && Date().timeIntervalSince(began) < 6 { try? await Task.sleep(for: .milliseconds(150)) }
            dismissSplash()
        }
        .task {
            if let dir = Screenshots.outDir { await Screenshots.run(store: store, nav: nav, dir: dir) }
            else if let dir = Recording.outDir { await Recording.run(store: store, dir: dir) }
            else if let secs = Soak.seconds { await Soak.run(store: store, for: secs) }
        }
        .sheet(item: Bindable(store).plan) { CleanupSheet(plan: $0) }
        .sheet(isPresented: Bindable(nav).showBasket) { BasketSheet().environment(store).environment(store.basket).environment(nav) }
        .sheet(isPresented: Bindable(store).needsOnboarding) { OnboardingView().environment(store).environment(nav).interactiveDismissDisabled() }
        .sheet(isPresented: Bindable(nav).showPalette) { PaletteView().environment(store).environment(nav) }
    }

    private func dismissSplash() {
        guard showSplash else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { showSplash = false }
    }
}
