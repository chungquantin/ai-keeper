import AppKit
import SwiftUI

/// The window server's own-window snapshot. Marked obsolete in recent SDKs but still exported, and capturing
/// a window your own process owns needs no Screen Recording permission.
@_silgen_name("CGWindowListCreateImage")
private func windowListCreateImage(_ rect: CGRect, _ options: UInt32, _ windowID: UInt32, _ imageOptions: UInt32) -> Unmanaged<CGImage>?

/// Takes the screenshots used on the website and README by driving the real app through its main screens.
/// Run with: AIKEEPER_DEMO=1 AIKEEPER_SHOTS=<folder> .build/debug/AIKeeper
/// Demo mode keeps real repositories, paths and spend out of the images.
@MainActor
enum Screenshots {
    static var outDir: String? { ProcessInfo.processInfo.environment["AIKEEPER_SHOTS"] }

    /// Captures a window exactly as composited on screen: glass sidebar, toolbar, shadow and all.
    @discardableResult
    static func captureWindow(_ window: NSWindow, to url: URL) -> Bool {
        guard let cg = windowListCreateImage(.null, 8, UInt32(window.windowNumber), 8)?.takeRetainedValue(),   // include window, best resolution
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
        try? data.write(to: url)
        print("wrote \(url.lastPathComponent) \(cg.width)x\(cg.height)")
        return true
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// Scrolls the main (widest) scroll view of the window.
    private static func scroll(_ window: NSWindow, to y: CGFloat) {
        guard let root = window.contentView else { return }
        let candidates = scrollViews(in: root).filter { $0.documentView != nil }
        guard let main = candidates.max(by: { $0.frame.width < $1.frame.width }) else { return }
        main.contentView.scroll(to: NSPoint(x: 0, y: y))
        main.reflectScrolledClipView(main.contentView)
    }

    static func run(store: Store, nav: NavState, dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dark = ProcessInfo.processInfo.environment["AIKEEPER_SHOTS_APPEARANCE"] == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let everything = ProcessInfo.processInfo.environment["AIKEEPER_SHOTS_ALL"] == "1"   // every sidebar destination, for design reviews
        NSApp.activate(ignoringOtherApps: true)   // so default buttons and the selection draw in their active state
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { print("no window"); exit(1) }
        window.setContentSize(NSSize(width: CGFloat(Double(ProcessInfo.processInfo.environment["AIKEEPER_SHOTS_WIDTH"] ?? "") ?? 1360), height: 980))
        window.center()
        window.makeKeyAndOrderFront(nil)
        func url(_ name: String) -> URL { URL(fileURLWithPath: "\(dir)/\(name).png") }
        func pause(_ s: Double = 1.6) async { try? await Task.sleep(for: .seconds(s)) }
        /// Activation is asynchronous, and an inactive window draws greyed controls and a smaller shadow.
        /// Keep asking until the app and the window really are active, then let the controls redraw.
        func focus() async {
            for _ in 0..<30 {
                if NSApp.isActive && window.isKeyWindow { break }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(500))
            if !(NSApp.isActive && window.isKeyWindow) { print("warning: window still inactive") }
        }

        /// Same wait for a dialog: it must be the key window of an active app, or its buttons draw grey.
        func settle(_ w: NSWindow) async {
            for _ in 0..<40 {
                if NSApp.isActive && w.isKeyWindow { break }
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(600))
            if !(NSApp.isActive && w.isKeyWindow) { print("warning: dialog still inactive") }
        }

        // Every area and tab of the redesigned app: AIKEEPER_SHOTS_AREAS=1.
        if ProcessInfo.processInfo.environment["AIKEEPER_SHOTS_AREAS"] == "1" {
            _ = store.addDemoJob()
            for a in Area.allCases {
                for t in a.pages {
                    nav.open(a, t)
                    await pause(a == .cleanup || t == .history ? 3.2 : 2.0)
                    await focus()
                    captureWindow(window, to: url("\(a.rawValue.lowercased())-\(t.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))"))
                }
            }
            // The full-page trace, on its Span tree tab with a failed call selected.
            if let s = store.sessions.first { nav.open(.sessions, .history); nav.openTrace = s; await pause(2.5); await focus(); captureWindow(window, to: url("trace-span-tree")) }
            nav.openTrace = nil
            nav.showPalette = true
            await pause(1.2)
            if let sheet = window.attachedSheet { await settle(sheet); captureWindow(sheet, to: url("palette")) }
            nav.showPalette = false
            await pause(0.8)
            // Dialogs: the confirm sheet and onboarding are attached sheets.
            nav.open(.cleanup, .review)
            await pause(1.5)
            let safe = store.entries.filter { ["feat-search-index", "experiment-graphql", "chore-deps-update"].contains($0.name) }
            store.plan = CleanupPlan(mode: .removeWorkspaces, entries: safe)
            await pause(1.8)
            if let sheet = window.attachedSheet { await settle(sheet); captureWindow(sheet, to: url("dialog-confirm")) }
            store.plan = nil
            await pause(1.0)
            store.basket.resetToSafe(); nav.showBasket = true
            await pause(1.5)
            if let sheet = window.attachedSheet { await settle(sheet); captureWindow(sheet, to: url("dialog-basket")) }
            nav.showBasket = false
            await pause(1.0)
            store.needsOnboarding = true
            await pause(1.8)
            if let sheet = window.attachedSheet { await settle(sheet); captureWindow(sheet, to: url("dialog-onboarding")) }
            store.needsOnboarding = false
            await pause(1.0)
            // Windows of their own: Settings, the menu-bar popover and the progress panel.
            func shoot<V: View>(_ v: V, _ name: String, width: CGFloat) async {
                let host = NSHostingView(rootView: v.environment(store).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
                let size = host.fittingSize
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
                [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { w.standardWindowButton($0)?.isHidden = true }
                w.contentView = host; w.setContentSize(size); w.center()
                await settle(w)
                captureWindow(w, to: url(name))
                w.orderOut(nil)
            }
            await shoot(SettingsView().environment(nav), "dialog-settings", width: 820)
            await shoot(MenuContent().environment(nav), "dialog-menubar", width: 340)
            let job = store.addDemoJob()
            await shoot(JobPanel(job: job, onClose: {}).padding(EdgeInsets(top: 0, leading: 28, bottom: 28, trailing: 28)), "dialog-progress", width: 560)
            exit(0)
        }

        // Overview: the top of the page, then the disk map further down.
        store.requestedDestination = .live
        await pause(0.8)
        store.requestedDestination = .today
        await pause(); scroll(window, to: 0); await pause(0.8)
        await focus(); captureWindow(window, to: url("overview"))
        scroll(window, to: 820); await pause(0.8)
        await focus(); captureWindow(window, to: url("overview-map"))
        scroll(window, to: 0)

        // Workspaces with the inspector open, and a cleanup running in the sidebar.
        _ = store.addDemoJob()
        store.requestedDestination = .workspaces(.all)
        await pause()
        if let pick = store.entries.first(where: { $0.name == "feat-search-index" }) { store.requestedSelection = pick.id }
        await pause(2.2)
        await focus(); captureWindow(window, to: url("workspaces"))

        for (name, section, wait) in [("agents", Destination.live, 1.8), ("usage", .cost, 2.4), ("system", .machine, 2.8)] {
            store.requestedDestination = section
            await pause(wait); scroll(window, to: 0); await pause(0.6)
            await focus()
            captureWindow(window, to: url(name))
        }

        if everything {
            for (name, section, wait) in [("deprecated", Destination.review, 2.0), ("tool-claude", .workspaces(.tool(.claude)), 2.0), ("duplicates", .duplicates, 1.8),
                                          ("containers", .containers, 2.2), ("disk", .folders, 2.8), ("vault", .savedSnapshots, 1.8), ("sessions", .history, 2.4), ("tools", .tools, 2.0)] {
                store.requestedDestination = section
                let isList: Bool = { switch section { case .review, .workspaces: return true; default: return false } }()
                await pause(isList ? wait + 1.4 : wait)
                if !isList { scroll(window, to: 0) }   // a table keeps its own offset; scrolling it by hand shifts its columns
                await pause(0.6)
                await focus()
                captureWindow(window, to: url(name))
            }
        }

        // Skills, with the one that needs attention open.
        store.requestedDestination = .skills
        if let risky = store.skills.first(where: { $0.name == "deploy-helper" }) { store.requestedSkill = risky.realPath }
        await pause(2.0); await focus()
        captureWindow(window, to: url("skills"))

        // The confirmation sheet (a separate window attached to the main one).
        store.jobs = []
        store.requestedDestination = .workspaces(.all)
        await pause(1.0)
        let safe = store.entries.filter { ["feat-search-index", "experiment-graphql", "chore-deps-update"].contains($0.name) }
        store.plan = CleanupPlan(mode: .removeWorkspaces, entries: safe)
        await pause(1.8)
        if let sheet = window.attachedSheet { await settle(sheet); captureWindow(sheet, to: url("cleanup-confirm")) } else { print("no sheet") }
        store.plan = nil
        await pause(1.0)

        if everything {
            // First run: the onboarding sheet.
            store.needsOnboarding = true
            await pause(1.8)
            if let sheet = window.attachedSheet { await settle(sheet); captureWindow(sheet, to: url("onboarding")) } else { print("no onboarding sheet") }
            store.needsOnboarding = false
            await pause(1.0)
        }

        // The progress panel, shown in its own window.
        let job = store.addDemoJob()
        let host = NSHostingView(rootView: JobPanel(job: job, onClose: {}).environment(store).padding(EdgeInsets(top: 0, leading: 28, bottom: 28, trailing: 28)).frame(width: 560)
            .background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.contentView = host
        panel.setContentSize(size)
        panel.center()
        await settle(panel)
        captureWindow(panel, to: url("cleanup-running"))
        exit(0)
    }
}
