import ServiceManagement
import SwiftUI

public struct AIKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = Store()
    @State private var nav = NavState()
    @State private var menuBar = MenuBarSetting()

    public init() {
        Migration.run()   // before anything reads settings
        var cliExit: Int32 = 0
        if CLI.handle(CommandLine.arguments, exitCode: &cliExit) { exit(cliExit) }
        BrandFonts.register()
        DeveloperFlags.run()
    }

    public var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(store)
                .environment(nav)
                .environment(store.basket)
                .font(.bBody)
                .tint(Brand.accent)
                .frame(minWidth: 1060, minHeight: 620)
                .task {
                    NSApplication.shared.setActivationPolicy(Prefs.showDockIcon || !Prefs.showMenuBar ? .regular : .accessory)
                    // scripts/dev.sh relaunches on every save; stealing focus each time would pull you out of your editor.
                    if ProcessInfo.processInfo.environment["AIKEEPER_DEV"] == nil { NSApplication.shared.activate(ignoringOtherApps: true) }
                    await store.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)   // the window can never be narrower than its content needs
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Rescan") { Task { await store.rescan() } }.keyboardShortcut("r")
                Button("Reclaim safe space") { store.basket.resetToSafe(); nav.showBasket = true }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Search") { nav.showPalette = true }.keyboardShortcut("k")
                Divider()
                Button("Today") { nav.open(.today) }.keyboardShortcut("1")
                Button("Traces") { nav.open(.sessions) }.keyboardShortcut("2")
                Button("Insights") { nav.open(.insights) }.keyboardShortcut("3")
                Button("Cleanup") { nav.open(.cleanup) }.keyboardShortcut("4")
                Button("Agents") { nav.open(.agents) }.keyboardShortcut("5")
            }
        }

        Settings { SettingsView().environment(store).environment(nav).tint(Brand.accent).font(.bBody) }

        MenuBarExtra(isInserted: Bindable(menuBar).isShown) {
            MenuContent().environment(store).environment(nav).tint(Brand.accent)
        } label: {
            MenuBarLabel(store: store, content: menuBar.content)
        }
        .menuBarExtraStyle(.window)
    }
}
