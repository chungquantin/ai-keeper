import AppKit
import SwiftUI

@_silgen_name("CGWindowListCreateImage")
private func windowListCreateImage(_ rect: CGRect, _ options: UInt32, _ windowID: UInt32, _ imageOptions: UInt32) -> Unmanaged<CGImage>?

/// Records the demo video: drives the real app through its main screens in demo mode and saves what the window
/// server composited for the app's own windows (the main window and any sheet), frame by frame.
/// Capturing your own windows needs no Screen Recording permission. `assets/video.swift` adds the title cards and
/// captions and encodes the result. Run through scripts/make-video.sh.
@MainActor
enum Recording {
    static var outDir: String? { ProcessInfo.processInfo.environment["AIKEEPER_VIDEO"] }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var mainID: UInt32 = 0
        private var sheet: (id: UInt32, topLeft: CGPoint)?   // screen coordinates, top-left origin
        private var rect = CGRect.zero
        private var running = false
        private var frames: [(Int, Double)] = []
        let dir: URL
        let t0 = Date()
        private let writers = DispatchQueue(label: "frames", attributes: .concurrent)
        private let gate = DispatchSemaphore(value: 6)
        private let group = DispatchGroup()

        init(dir: URL) { self.dir = dir }

        func update(main: UInt32, sheet: (id: UInt32, topLeft: CGPoint)?, rect: CGRect) { lock.lock(); mainID = main; self.sheet = sheet; self.rect = rect; lock.unlock() }

        /// Main window cropped to `rect`, with the sheet (its own window) drawn on top where it sits on screen.
        private func grab(main: UInt32, sheet: (id: UInt32, topLeft: CGPoint)?, rect: CGRect) -> CGImage? {
            guard let base = windowListCreateImage(rect, 8, main, 8)?.takeRetainedValue() else { return nil }
            guard let sheet, let top = windowListCreateImage(.null, 8, sheet.id, 8)?.takeRetainedValue() else { return base }
            let scale = CGFloat(base.width) / rect.width
            guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return base }
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            // The sheet's capture carries a shadow margin: 56pt on the left and 38pt above the window.
            let x = (sheet.topLeft.x - rect.minX - 56) * scale
            let yTop = (sheet.topLeft.y - rect.minY - 38) * scale
            ctx.draw(top, in: CGRect(x: x, y: CGFloat(base.height) - yTop - CGFloat(top.height), width: CGFloat(top.width), height: CGFloat(top.height)))
            return ctx.makeImage()
        }

        func start() {
            running = true
            Thread.detachNewThread { [self] in
                var n = 0
                while true {
                    lock.lock(); let main = mainID, sheet = self.sheet, rect = self.rect, on = running; lock.unlock()
                    if !on { break }
                    let t = Date().timeIntervalSince(t0)
                    let started = Date()
                    if main != 0, let cg = grab(main: main, sheet: sheet, rect: rect) {
                        let url = dir.appendingPathComponent(String(format: "frame_%05d.png", n))
                        frames.append((n, t)); n += 1
                        gate.wait(); group.enter()
                        writers.async { [gate, group] in
                            if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                                CGImageDestinationAddImage(d, cg, [kCGImagePropertyPNGDictionary: [:]] as CFDictionary)
                                CGImageDestinationFinalize(d)
                            }
                            gate.signal(); group.leave()
                        }
                    }
                    let spare = 1.0 / 30 - Date().timeIntervalSince(started)   // 30 fps is plenty for a screen recording
                    if spare > 0 { Thread.sleep(forTimeInterval: spare) }
                }
            }
        }

        func stop() -> [(Int, Double)] {
            lock.lock(); running = false; lock.unlock()
            Thread.sleep(forTimeInterval: 0.3)
            group.wait()
            return frames
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func setScroll(_ window: NSWindow, to y: CGFloat) {
        guard let root = window.contentView,
              let main = scrollViews(in: root).filter({ $0.documentView != nil }).max(by: { $0.frame.width < $1.frame.width }) else { return }
        main.contentView.scroll(to: NSPoint(x: 0, y: y))
        main.reflectScrolledClipView(main.contentView)
    }

    static func run(store: Store, dir: String) async {
        let outURL = URL(fileURLWithPath: dir)
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { print("no window"); exit(1) }
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<40 where !(NSApp.isActive && window.isKeyWindow) {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(250))
        }
        store.requestedSection = .agents
        try? await Task.sleep(for: .seconds(1))
        store.requestedSection = .overview
        try? await Task.sleep(for: .seconds(1.5))
        setScroll(window, to: 0)

        let capture = Capture(dir: outURL)
        let primaryH = NSScreen.screens[0].frame.height
        func refresh() {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }   // an inactive window draws grey controls
            var sheet: (id: UInt32, topLeft: CGPoint)?
            if let s = window.attachedSheet { sheet = (UInt32(s.windowNumber), CGPoint(x: s.frame.minX, y: primaryH - s.frame.maxY)) }
            let f = window.frame.insetBy(dx: -56, dy: -56)
            capture.update(main: UInt32(window.windowNumber), sheet: sheet, rect: CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height))
        }
        refresh()
        var events: [[String: Any]] = []
        var scene = ""
        func caption(_ text: String) { events.append(["t": Date().timeIntervalSince(capture.t0), "caption": text]); scene = text }
        func wait(_ s: Double) async {   // keep the capture's window list fresh while waiting
            let end = Date().addingTimeInterval(s)
            while Date() < end { refresh(); try? await Task.sleep(for: .milliseconds(60)) }
        }
        func glide(from a: CGFloat, to b: CGFloat, over s: Double) async {
            let start = Date()
            while true {
                let p = min(1, Date().timeIntervalSince(start) / s)
                let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2   // ease in out
                setScroll(window, to: a + (b - a) * CGFloat(e)); refresh()
                if p >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }

        capture.start()
        await wait(0.6)

        // 1. How much, and where.
        caption("See how much your coding agents left behind")
        await wait(3.0)
        caption("See exactly where the disk went")
        await glide(from: 0, to: 820, over: 2.4)
        await wait(2.0)
        await glide(from: 820, to: 0, over: 1.2)

        // 2. Which worktrees are still needed.
        caption("Know which worktrees are still needed")
        store.requestedSection = .all
        await wait(1.4)
        if let pick = store.entries.first(where: { $0.name == "feat-search-index" }) { store.requestedSelection = pick.id }
        await wait(4.2)

        // 3. Review, then clean in the background.
        caption("Review exactly what gets removed")
        let safe = store.entries.filter { ["feat-search-index", "experiment-graphql", "chore-deps-update"].contains($0.name) }
        store.plan = CleanupPlan(mode: .removeWorkspaces, entries: safe)
        await wait(4.0)
        store.plan = nil
        await wait(0.8)
        caption("Cleanup runs in the background")
        let job = store.addDemoJob()
        job.status.freed = 3_000_000_000
        job.status.started = Date().addingTimeInterval(-12)
        let total = job.status.total
        let begin = Date()
        while true {
            let p = min(1, Date().timeIntervalSince(begin) / 5.0)
            job.status.freed = Int64(Double(total) * (0.08 + 0.92 * p))
            refresh()
            if p >= 1 { break }
            try? await Task.sleep(for: .milliseconds(60))
        }
        job.outcome = CleanupOutcome(cancelled: false, freed: total, failures: [])
        job.state = .finished
        await wait(1.8)

        // 4. The rest of the app.
        caption("Watch every running agent and what it costs")
        store.requestedSection = .agents
        await wait(4.0)
        caption("Track AI spend across tools")
        store.requestedSection = .usage
        await wait(4.0)
        caption("Check system health at a glance")
        store.requestedSection = .memory
        await wait(3.6)

        let frames = capture.stop()
        let info: [String: Any] = [
            "frames": frames.map { [$0.0, $0.1] },
            "events": events,
            "duration": frames.last?.1 ?? 0,
        ]
        let data = try! JSONSerialization.data(withJSONObject: info)
        try! data.write(to: outURL.appendingPathComponent("timeline.json"))
        print("recorded \(frames.count) frames over \(String(format: "%.1f", frames.last?.1 ?? 0))s (\(String(format: "%.1f", Double(frames.count) / max(frames.last?.1 ?? 1, 1))) fps)")
        exit(0)
    }
}
