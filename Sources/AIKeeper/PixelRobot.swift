import SwiftUI

// The Keeper robot and its pixel world: the same art as the website and the launch film.
// Used for the running-job indicator in the sidebar, empty states, and the loading screen.

extension Color {
    init(px hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

enum Pixel {
    struct Sprite {
        let w: Int, h: Int
        let px: [(x: Int, y: Int, c: Color)]
    }

    static let ink: UInt32 = 0x0C1240
    static let palette: [Character: UInt32] = ["W": 0xFFFFFF, "L": 0xDFE5FF, "M": 0x9AA8F5, "K": 0x0C1240, "D": 0x1A2A9A, "Y": 0xFFB020, "A": 0xFFB020, "B": 0x35C9A0,
                                               "G": 0xC9D2FF, "E": 0x8392F2]

    /// Turns rows of characters into pixels and adds a one pixel ink outline, the way every sprite on the site is made.
    static func compile(_ rows: [String], outline: UInt32? = ink) -> Sprite {
        let w = rows.map(\.count).max() ?? 0, h = rows.count
        var set: [String: UInt32] = [:]
        for (y, r) in rows.enumerated() { for (x, ch) in r.enumerated() where ch != "." { if let c = palette[ch] { set["\(x),\(y)"] = c } } }
        var out: [(x: Int, y: Int, c: Color)] = []
        func has(_ x: Int, _ y: Int) -> Bool { set["\(x),\(y)"] != nil }
        for y in -1...h { for x in -1...w {
            if let c = set["\(x),\(y)"] { out.append((x, y, Color(px: c))) }
            else if let o = outline, has(x + 1, y) || has(x - 1, y) || has(x, y + 1) || has(x, y - 1) { out.append((x, y, Color(px: o))) }
        } }
        return Sprite(w: w, h: h, px: out)
    }

    static func robotRows(wheel: Bool, sleep: Bool, led: Character) -> [String] {
        [".....\(led)........", ".....\(led)........", "...WWWWWWWW...", "..WWWWWWWWWW..",
         sleep ? "..WWWWWWWWWW.." : "..WWKKWWKKWW..", "..WWKKWWKKWW..", "..WWWWWWWWWW..", "...WWWWWWWW...",
         "..LLLLLLLLLM..", ".LLLLDDDDLLLLM", ".LLLLDYYDLLLLM", ".LLLLDDDDLLLLM", "..LLLLLLLLLM..", "...MMMMMMMM...",
         wheel ? "..KKKK..KKKK.." : ".KKKKK..KKKKK.", wheel ? ".KKKKK..KKKKK." : "..KKK....KKK.."]
    }

    /// [led][wheel][asleep]
    static let robots: [[[Sprite]]] = [0, 1].map { l in [false, true].map { w in [false, true].map { s in compile(robotRows(wheel: w, sleep: s, led: l == 0 ? "A" : "B")) } } }
    static func robot(led: Int = 0, wheel: Bool = false, asleep: Bool = false) -> Sprite { robots[led % 2][wheel ? 1 : 0][asleep ? 1 : 0] }
    static let agents: [Sprite] = [false, true].map { f in
        compile(["..GGGG..", ".GGGGGG.", ".GKGGKG.", ".GGGGGG.", "..GGGG..", ".EEEEEE.", ".EEEEEE.", f ? "..E..E.." : ".E....E.", ".EE..EE."])
    }

    struct Crate {
        let w: Int, h: Int
        let pix: [(x: Int, y: Int, c: Color, h: Double)]
        init(w: Int, h: Int, seed: Int) {
            self.w = w; self.h = h
            var p: [(x: Int, y: Int, c: Color, h: Double)] = []
            for py in 0..<h { for px in 0..<w {
                let top = py == 0, bot = py >= h - 2, edge = px == w - 1
                let plank = py == h / 2 || (px == w / 2 && py > 1 && py < h - 2 && w > 12)
                let c: UInt32 = top ? 0xFFD36B : (bot || edge) ? 0xC27A00 : plank ? 0xE69A10 : 0xFFB020
                let hash = UInt32(truncatingIfNeeded: (px &* 73856093) ^ (py &* 19349663) ^ (seed &* 83492791))
                p.append((px, py, Color(px: c), Double(hash % 1000) / 1000))
            } }
            pix = p
        }
    }
}

extension GraphicsContext {
    /// Draws a sprite with its top left at `p`, one source pixel = `u` points. Positions are snapped so pixels never blur.
    func draw(_ s: Pixel.Sprite, at p: CGPoint, scale u: CGFloat, flip: Bool = false) {
        for (x, y, c) in s.px {
            let xx = flip ? s.w - 1 - x : x
            fill(Path(CGRect(x: (p.x + CGFloat(xx) * u).rounded(), y: (p.y + CGFloat(y) * u).rounded(), width: u, height: u)), with: .color(c))
        }
    }
    func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ u: CGFloat, _ c: Color) {
        fill(Path(CGRect(x: (x * u).rounded(), y: (y * u).rounded(), width: w * u, height: h * u)), with: .color(c))
    }
}

// MARK: - The running robot (sidebar activity)

/// A robot vacuuming crates off a conveyor: shows that a cleanup is running without needing a number.
struct RobotRunner: View {
    var stopping = false
    var fixedTime: Double? = nil    // for snapshots
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion || fixedTime != nil)) { tl in
            Canvas { ctx, size in
                let t = fixedTime ?? (reduceMotion ? 1.3 : tl.date.timeIntervalSinceReferenceDate)
                let u: CGFloat = 2
                let lw = size.width / u, floorY = size.height / u - 4
                // floor, with dashes sliding past
                ctx.px(0, floorY, lw, 1, u, Color.primary.opacity(0.14))
                let off = (t * 30).truncatingRemainder(dividingBy: 12)
                var x = -off
                while x < lw { ctx.px(x, floorY + 2, 5, 1, u, Color.primary.opacity(0.08)); x += 12 }
                // robot
                let rx: CGFloat = 4, wheel = !reduceMotion && Int(t * 9) % 2 == 0
                let bob: CGFloat = (!reduceMotion && Int(t * 9) % 2 == 0) ? 0 : 1
                let robot = Pixel.robot(led: 0, wheel: wheel, asleep: stopping)
                let nozzle = rx + 16
                // crates arrive from the right and are swallowed at the nozzle
                let period = 1.35, speed = 24.0
                for k in max(0, Int(t / period) - 6)...max(0, Int(t / period)) {
                    let born = Double(k) * period, cx = lw + 2 - CGFloat((t - born) * speed)
                    let cw = 8 + (k * 5) % 6, ch = 6 + (k * 3) % 5
                    guard cx + CGFloat(cw) > nozzle else { continue }
                    let crate = Pixel.Crate(w: cw, h: ch, seed: k)
                    for p in crate.pix where cx + CGFloat(p.x) >= nozzle { ctx.px(cx + CGFloat(p.x), floorY - CGFloat(ch) + CGFloat(p.y), 1, 1, u, p.c) }
                    if cx < nozzle + 5 { for i in 0..<3 { ctx.px(nozzle + CGFloat((i * 7 + Int(t * 20)) % 4), floorY - 8 + CGFloat(i * 2), 1, 1, u, Color(px: 0xFFD36B)) } }
                }
                ctx.draw(robot, at: CGPoint(x: (rx - 1) * u, y: (floorY - 18 + bob) * u), scale: u)
                ctx.px(nozzle - 1, floorY - 8, 3, 4, u, Color(px: Pixel.ink)); ctx.px(nozzle, floorY - 7, 1, 2, u, Color(px: 0xFFB020))
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }
}

/// A tiny robot for places where a spinner used to be.
struct RobotSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0, paused: reduceMotion)) { tl in
            Canvas { ctx, size in
                let on = !reduceMotion && Int(tl.date.timeIntervalSinceReferenceDate * 6) % 2 == 0
                ctx.draw(Pixel.robot(wheel: on), at: CGPoint(x: 1, y: on ? 0 : 1), scale: 1)
            }
        }
        .frame(width: 18, height: 19)
        .accessibilityHidden(true)
    }
}

/// An asleep robot for lists that have nothing to show.
struct SleepingRobot: View {
    var scale: CGFloat = 4
    var body: some View {
        Canvas { ctx, size in
            let s = Pixel.robot(asleep: true)
            ctx.draw(s, at: CGPoint(x: scale, y: scale), scale: scale)
            ctx.draw(Text("z").font(.system(size: scale * 3.4, weight: .heavy, design: .rounded)).foregroundStyle(Color(px: 0x7F93F7)), at: CGPoint(x: scale * 17, y: scale * 2))
        }
        .frame(width: scale * 22, height: scale * 19)
        .accessibilityHidden(true)
    }
}

// MARK: - Loading screen

/// What is on screen while the app finds your workspaces: agent bots drop crates, Keeper robots vacuum them up.
struct SplashView: View {
    @EnvironmentObject var store: Store
    let start = Date()
    var onSkip: () -> Void = {}
    var fixedTime: Double? = nil    // for snapshots
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Item { var x: Double, yb: Double, w: Int, h: Int, gb: Double, spawn: Double, cs: Double = 0, ce: Double = 0, robot: Int = 0, agentFromLeft = false }
    private struct Leg { var t0: Double, t1: Double, x0: Double, x1: Double, y0: Double, y1: Double, dir: Double, clean: Bool }

    private static let LW = 200.0, LH = 110.0, horizon = 64.0
    private static let plan: (items: [Item], robots: [[Leg]]) = {
        var rng = SeededRandom(seed: 9)
        var items: [Item] = (0..<22).map { k in
            let gb = 0.5 + rng.next() * rng.next() * 6
            return Item(x: 16 + rng.next() * 150, yb: 80 + rng.next() * 24, w: Int(min(20, max(9, 7 + gb * 2.2))), h: Int(min(15, max(7, 6 + gb * 1.5))), gb: gb, spawn: 0.3 + Double(k) * 0.42, agentFromLeft: rng.next() < 0.5)
        }
        var robots: [[Leg]] = [[], [], []]
        var pos: [(x: Double, y: Double, free: Double)] = [(-20, 90, 1.6), (220, 96, 1.9), (-20, 100, 2.2)]
        for i in items.indices.sorted(by: { items[$0].spawn < items[$1].spawn }) {
            let c = items[i]
            func plan(_ r: Int) -> (end: Double, t0: Double, stop: Double, right: Bool, walk: Double, dur: Double) {
                let right = pos[r].x < c.x, stop = right ? c.x - 17 : c.x + Double(c.w) + 3
                let walk = abs(stop - pos[r].x) / 80 + 0.12, t0 = max(pos[r].free, c.spawn + 0.25), dur = 0.35 + c.gb * 0.06
                return (t0 + walk + dur, t0, stop, right, walk, dur)
            }
            let r = (0..<3).min(by: { plan($0).end < plan($1).end })!, p = plan(r)
            robots[r].append(Leg(t0: p.t0, t1: p.t0 + p.walk, x0: pos[r].x, x1: p.stop, y0: pos[r].y, y1: c.yb, dir: p.right ? 1 : -1, clean: false))
            robots[r].append(Leg(t0: p.t0 + p.walk, t1: p.t0 + p.walk + p.dur, x0: p.stop, x1: p.stop, y0: c.yb, y1: c.yb, dir: p.right ? 1 : -1, clean: true))
            items[i].cs = p.t0 + p.walk; items[i].ce = p.t0 + p.walk + p.dur; items[i].robot = r
            pos[r] = (p.stop, c.yb, items[i].ce + 0.03)
        }
        return (items, robots)
    }()

    private struct SeededRandom {
        var s: UInt64
        init(seed: UInt64) { s = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    }

    private var status: String {
        switch store.phase {
        case .discovering, .idle: return "Finding your workspaces"
        case .measuring(let d, let t): return "Measuring \(d) of \(t)"
        case .done: return "Ready"
        }
    }
    private var fraction: Double? { if case .measuring(let d, let t) = store.phase, t > 0 { return Double(d) / Double(t) } else if store.phase == .done { return 1 } else { return nil } }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || fixedTime != nil)) { tl in
                Canvas { ctx, size in scene(&ctx, size, t: fixedTime ?? (reduceMotion ? 4.2 : tl.date.timeIntervalSince(start) + 0.4)) }
            }
            VStack(spacing: 10) {
                Text("AI Keeper").font(.system(size: 46, weight: .heavy, design: .rounded)).tracking(-1).foregroundStyle(.white)
                Text(status).font(.system(.title3, design: .rounded, weight: .medium)).foregroundStyle(Color(px: 0xDFE5FF)).monospacedDigit()
                PixelBar(fraction: fraction).frame(width: 240, height: 10).padding(.top, 4)
            }
            .padding(.top, 70).frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .background(Color(px: 0x0A1050))
        .contentShape(Rectangle())
        .onTapGesture { onSkip() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI Keeper is starting. \(status)")
    }

    private func scene(_ ctx: inout GraphicsContext, _ size: CGSize, t: Double) {
        let u = max(3, floor(min(size.width / Self.LW, size.height / Self.LH)))
        let ox = ((size.width - Self.LW * u) / 2).rounded(), oy = (size.height - Self.LH * u).rounded()
        let hy = oy + Self.horizon * u
        // dusk sky and carpet, edge to edge
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: hy)), with: .linearGradient(Gradient(colors: [Color(px: 0x0A1050), Color(px: 0x16228A), Color(px: 0x2236C8)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: hy)))
        ctx.fill(Path(CGRect(x: 0, y: hy, width: size.width, height: size.height - hy)), with: .linearGradient(Gradient(colors: [Color(px: 0x1A2A9A), Color(px: 0x3A4FE0)]), startPoint: CGPoint(x: 0, y: hy), endPoint: CGPoint(x: 0, y: size.height)))
        // skyline, in three layers; the nearest has lit windows
        var rng = SeededRandom(seed: 4)
        let sx = Int(ceil(size.width / u)) + 4
        for (li, col) in [Color(px: 0x2A3FC0), Color(px: 0x1E2FA8), Color(px: 0x10196E)].enumerated() {
            var x = -2
            while x < sx {
                let w = 3 + Int(rng.next() * 6), h = 8 + li * 5 + Int(rng.next() * Double(14 + li * 10))
                ctx.fill(Path(CGRect(x: CGFloat(x) * u, y: hy - CGFloat(h) * u, width: CGFloat(w) * u, height: CGFloat(h) * u)), with: .color(col))
                if li == 2 { var y = 3; while y < h - 1 { var xx = 1; while xx < w - 1 { if rng.next() < 0.2 { ctx.fill(Path(CGRect(x: CGFloat(x + xx) * u, y: hy - CGFloat(h - y) * u, width: u, height: u)), with: .color(rng.next() < 0.6 ? Color(px: 0xFFB020) : .white)) }; xx += 2 }; y += 3 } }
                x += w + (rng.next() < 0.4 ? 1 : 0)
            }
        }
        ctx.fill(Path(CGRect(x: 0, y: hy - 2 * u, width: size.width, height: 2 * u)), with: .color(Color(px: Pixel.ink)))
        var ly = hy + 6 * u; while ly < size.height { ctx.fill(Path(CGRect(x: 0, y: ly, width: size.width, height: u)), with: .color(.white.opacity(0.05))); ly += 6 * u }

        // actors, drawn back to front
        struct Draw { var y: Double; var f: (inout GraphicsContext) -> Void }
        var draws: [Draw] = []
        let at: (Double, Double) -> CGPoint = { CGPoint(x: ox + $0 * u, y: oy + $1 * u) }
        for (i, c) in Self.plan.items.enumerated() {
            // the agent that leaves this crate
            let a0 = c.spawn - 1.1, a1 = c.spawn, a2 = c.spawn + 0.9
            if t > a0 && t < a2 {
                let sx = c.agentFromLeft ? -12.0 : 212.0, dx = c.x + (c.agentFromLeft ? -6 : Double(c.w) + 4)
                let ax = t < a1 ? sx + (dx - sx) * smooth((t - a0) / (a1 - a0)) : dx + (sx - dx) * smooth((t - a1 - 0.2) / (a2 - a1 - 0.2))
                let movingRight = c.agentFromLeft ? t < a1 : t >= a1
                draws.append(Draw(y: c.yb + 1) { g in g.draw(Pixel.agents[Int(t * 8) % 2], at: at(ax - 1, c.yb - 9), scale: u, flip: !movingRight) })
            }
            let rem = t < c.spawn ? 0 : t >= c.ce ? 0 : t < c.cs ? 1 : 1 - (t - c.cs) / (c.ce - c.cs)
            if rem > 0 {
                let crate = Pixel.Crate(w: c.w, h: c.h, seed: i)
                draws.append(Draw(y: c.yb) { g in
                    g.fill(Path(CGRect(x: at(c.x - 1, c.yb).x, y: at(0, c.yb).y, width: CGFloat(c.w + 3) * u, height: u)), with: .color(Color(px: Pixel.ink).opacity(0.3)))
                    for p in crate.pix where p.h < rem { g.fill(Path(CGRect(x: (at(c.x + Double(p.x), 0).x).rounded(), y: (at(0, c.yb - Double(c.h) + Double(p.y)).y).rounded(), width: u, height: u)), with: .color(p.c)) }
                })
            }
        }
        for (ri, legs) in Self.plan.robots.enumerated() {
            var pos: (x: Double, y: Double, dir: Double, clean: Bool, crate: Item?) = (legs.first?.x0 ?? -20, legs.first?.y0 ?? 90, 1, false, nil)
            if let first = legs.first, t < first.t0 { pos = (first.x0, first.y0, first.dir, false, nil) }
            for leg in legs where t >= leg.t0 {
                if t < leg.t1 { let p = smooth((t - leg.t0) / (leg.t1 - leg.t0)); pos = (leg.x0 + (leg.x1 - leg.x0) * p, leg.y0 + (leg.y1 - leg.y0) * p, leg.dir, leg.clean, nil) }
                else { pos = (leg.x1, leg.y1, leg.dir, false, nil) }
            }
            if let c = Self.plan.items.first(where: { $0.robot == ri && t >= $0.cs && t < $0.ce }) { pos.clean = true; pos.crate = c; pos.x = c.cs > 0 ? (legs.first(where: { $0.clean && $0.t0 == c.cs })?.x1 ?? pos.x) : pos.x }
            let p = pos
            draws.append(Draw(y: p.y) { g in
                g.fill(Path(CGRect(x: at(p.x, p.y).x, y: at(0, p.y).y, width: 16 * u, height: u)), with: .color(Color(px: Pixel.ink).opacity(0.3)))
                g.draw(Pixel.robot(led: ri, wheel: Int(t * 9) % 2 == 0), at: at(p.x - 1, p.y - 18), scale: u, flip: p.dir < 0)
                let nx = p.dir > 0 ? p.x + 16 : p.x - 2, ny = p.y - 7
                g.fill(Path(CGRect(x: at(nx - 1, 0).x, y: at(0, ny - 1).y, width: 3 * u, height: 4 * u)), with: .color(Color(px: Pixel.ink)))
                g.fill(Path(CGRect(x: at(nx, 0).x, y: at(0, ny).y, width: u, height: 2 * u)), with: .color(Color(px: p.clean ? 0xFFB020 : 0x7F93F7)))
                if p.clean, let c = p.crate {
                    for k in 0..<12 {
                        let ph = (t * 3.1 + Double(k) / 12).truncatingRemainder(dividingBy: 1), cx = c.x + Double((k * 7) % c.w), cy = c.yb - Double(c.h) + Double((k * 5) % c.h)
                        let x = cx + (nx - cx) * ph * ph, y = cy + (ny - cy) * ph - sin(Double.pi * ph) * 5
                        g.fill(Path(CGRect(x: at(x, 0).x.rounded(), y: at(0, y).y.rounded(), width: u, height: u)), with: .color(ph > 0.85 ? .white : Color(px: 0xFFD36B)))
                    }
                }
            })
        }
        draws.sort { $0.y < $1.y }
        for d in draws { d.f(&ctx) }
    }

    private func smooth(_ x: Double) -> Double { let v = min(1, max(0, x)); return v * v * (3 - 2 * v) }
}

/// A progress bar made of squares: filled amber, the rest dim.
struct PixelBar: View {
    var fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || fraction != nil)) { tl in
            Canvas { ctx, size in
                let n = 24, cell = size.width / CGFloat(n)
                let sweep = Int(tl.date.timeIntervalSinceReferenceDate * 14) % (n + 6)
                for i in 0..<n {
                    let on: Bool
                    if let f = fraction { on = Double(i) < f * Double(n) } else { on = i >= sweep - 5 && i <= sweep }
                    ctx.fill(Path(CGRect(x: CGFloat(i) * cell + 1, y: 0, width: cell - 2, height: size.height)), with: .color(on ? Color(px: 0xFFB020) : .white.opacity(0.14)))
                }
            }
        }
    }
}

#if DEBUG
/// `AIKeeper --pixelshots <folder>` renders the robot views to PNGs, so they can be checked without opening the app.
enum PixelShots {
    @MainActor static func run(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func save<V: View>(_ v: V, _ name: String, _ w: CGFloat, _ h: CGFloat) {
            let r = ImageRenderer(content: v.frame(width: w, height: h)); r.scale = 1
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        let store = Store()
        for t in [0.8, 2.2, 3.6, 5.0] { save(SplashView(fixedTime: t).environmentObject(store), "splash-\(t)", 1060, 620) }
        for t in [1.0, 1.4] { save(RobotRunner(fixedTime: t).padding().background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark), "runner-\(t)", 260, 80) }
        save(SleepingRobot().padding().background(Color(nsColor: .windowBackgroundColor)), "sleeping", 160, 120)
        for scheme in [ColorScheme.light, .dark] {
            let sample = VStack(alignment: .leading, spacing: 12) {
                Text("You can get back").font(.bCallout).foregroundStyle(.secondary)
                Text("107.9 GB").font(.figure(30))
                PixelMeter(value: 0.62).frame(width: 260)
                HStack { Pill(text: "Safe to remove", color: Brand.accent); Pill(text: "Uncommitted", color: .red) }
                Button("Remove 3 workspaces") {}.buttonStyle(.brandProminent).tint(Brand.accent)
            }.padding(20).panel().padding(24).background(Brand.surface).environment(\.colorScheme, scheme).font(.bBody)
            save(sample, "brand-\(scheme == .dark ? "dark" : "light")", 360, 260)
        }
        let ids = ["claude", "codex", "conductor", "superset", "pi", "zcode", "cursor", "goose", "gemini", "aider", "opencode", "git"]
        for scheme in [ColorScheme.light, .dark] {
            save(HStack(spacing: 14) { ForEach(ids, id: \.self) { ToolIcon(id: $0, size: 30) } }.padding(16)
                    .background(scheme == .dark ? Color.black : Color.white).foregroundStyle(scheme == .dark ? Color.white : Color.black), "logos-\(scheme == .dark ? "dark" : "light")", 640, 80)
        }
    }
}
#endif
