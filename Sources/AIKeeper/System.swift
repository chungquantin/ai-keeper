import Darwin
import IOKit
import IOKit.ps
import SwiftUI

// MARK: - Sampling (native APIs, no subprocesses)

struct BatteryInfo {
    var level: Double          // 0...1
    var charging: Bool
    var onAC: Bool
    var minutesRemaining: Int? // to empty, or to full while charging
    var cycles: Int?
    var healthPercent: Int?
    var temperatureC: Double?
}

struct SystemSnapshot {
    var cpuTotal = 0.0                 // 0...1
    var cores: [Double] = []
    var load: (Double, Double, Double) = (0, 0, 0)
    var memUsed: Int64 = 0, memTotal: Int64 = 0, memAvailable: Int64 = 0
    var swapUsed: Int64 = 0, swapTotal: Int64 = 0
    var pressure = 1                   // 1 normal, 2 warning, 4 critical
    var diskUsed: Int64 = 0, diskTotal: Int64 = 0
    var readBps = 0.0, writeBps = 0.0
    var netDown = 0.0, netUp = 0.0
    var netInterface: String?, netIP: String?
    var battery: BatteryInfo?

    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
}

struct MachineInfo {
    var model = "Mac", chip = "", cores = 0, memory: Int64 = 0, os = "", uptime: TimeInterval = 0

    static func read() -> MachineInfo {
        var m = MachineInfo()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if svc != 0 {
            if let d = IORegistryEntryCreateCFProperty(svc, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                m.model = String(decoding: d.filter { $0 != 0 }, as: UTF8.self)
            }
            IOObjectRelease(svc)
        }
        m.chip = sysString("machdep.cpu.brand_string")
        m.cores = ProcessInfo.processInfo.processorCount
        m.memory = Int64(ProcessInfo.processInfo.physicalMemory)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        m.os = "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
        // Wall-clock time since boot. `systemUptime` stops counting while the Mac sleeps.
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 { m.uptime = Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))) }
        else { m.uptime = ProcessInfo.processInfo.systemUptime }
        return m
    }

    static func sysString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

/// Keeps the previous counters so each sample can turn totals into per-second rates.
final class SystemSampler {
    private var prevTicks: [(UInt32, UInt32, UInt32, UInt32)] = []
    private var prevDisk: (r: UInt64, w: UInt64)?
    private var prevNet: [String: (UInt32, UInt32)] = [:]
    private var prevTime: Date?

    func sample() -> SystemSnapshot {
        var s = SystemSnapshot()
        let now = Date()
        let dt = prevTime.map { max(now.timeIntervalSince($0), 0.2) } ?? 0
        prevTime = now

        // CPU, per core, from tick deltas.
        let ticks = Self.cpuTicks()
        if ticks.count == prevTicks.count, !ticks.isEmpty {
            var busyAll = 0.0, totalAll = 0.0
            for (cur, old) in zip(ticks, prevTicks) {
                let user = Double(cur.0 &- old.0), sys = Double(cur.1 &- old.1), idle = Double(cur.2 &- old.2), nice = Double(cur.3 &- old.3)
                let total = user + sys + idle + nice
                s.cores.append(total > 0 ? (user + sys + nice) / total : 0)
                busyAll += user + sys + nice; totalAll += total
            }
            s.cpuTotal = totalAll > 0 ? busyAll / totalAll : 0
        }
        prevTicks = ticks
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        s.load = (l[0], l[1], l[2])

        // Memory and swap.
        Self.memory(into: &s)

        // Disk capacity and I/O.
        if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            s.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            s.diskUsed = max(0, s.diskTotal - (v.volumeAvailableCapacityForImportantUsage ?? 0))
        }
        let io = Self.diskCounters()
        if let p = prevDisk, dt > 0 { s.readBps = Double(io.r &- p.r) / dt; s.writeBps = Double(io.w &- p.w) / dt }
        prevDisk = io

        // Network (physical en* interfaces; tunnels would double-count VPN traffic).
        let net = Self.netCounters()
        var down = 0.0, up = 0.0
        for (name, cur) in net.counters {
            if let old = prevNet[name], dt > 0 { down += Double(cur.0 &- old.0); up += Double(cur.1 &- old.1) }
        }
        if dt > 0 { s.netDown = down / dt; s.netUp = up / dt }
        prevNet = net.counters
        s.netInterface = net.primary; s.netIP = net.ip

        s.battery = Self.battery()
        return s
    }

    // MARK: Mach / sysctl

    static func cpuTicks() -> [(UInt32, UInt32, UInt32, UInt32)] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { i in
            let b = i * Int(CPU_STATE_MAX)
            return (UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]), UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                    UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]), UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
        }
    }

    static func memory(into s: inout SystemSnapshot) {
        var stats = vm_statistics64()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt) }
        }
        let page = Int64(sysconf(_SC_PAGESIZE))
        s.memTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        if ok == KERN_SUCCESS {
            s.memUsed = (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
            s.memAvailable = (Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.purgeable_count)) * page
        }
        var sw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0 { s.swapUsed = Int64(sw.xsu_used); s.swapTotal = Int64(sw.xsu_total) }
        var level: Int32 = 1
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsize, nil, 0) == 0 { s.pressure = Int(level) }
    }

    // MARK: IOKit

    static func diskCounters() -> (r: UInt64, w: UInt64) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0
        while case let svc = IOIteratorNext(iter), svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any], let st = d["Statistics"] as? [String: Any] {
                r += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(svc)
        }
        return (r, w)
    }

    static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Double ?? Double(d[kIOPSCurrentCapacityKey] as? Int ?? 0)
            let max = d[kIOPSMaxCapacityKey] as? Double ?? Double(d[kIOPSMaxCapacityKey] as? Int ?? 100)
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let mins = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            var b = BatteryInfo(level: max > 0 ? cur / max : 0, charging: charging, onAC: onAC,
                                minutesRemaining: (mins ?? -1) > 0 ? mins : nil)
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if svc != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let p = props?.takeRetainedValue() as? [String: Any] {
                    b.cycles = (p["CycleCount"] as? NSNumber)?.intValue
                    let design = (p["DesignCapacity"] as? NSNumber)?.doubleValue ?? 0
                    let rawMax = (p["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue ?? 0
                    if design > 0, rawMax > 0 { b.healthPercent = Int((rawMax / design * 100).rounded()) }
                    if let t = (p["Temperature"] as? NSNumber)?.doubleValue { b.temperatureC = t / 100 }
                }
                IOObjectRelease(svc)
            }
            return b
        }
        return nil
    }

    // MARK: Network

    static func netCounters() -> (counters: [String: (UInt32, UInt32)], primary: String?, ip: String?) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return ([:], nil, nil) }
        defer { freeifaddrs(ifap) }
        var out: [String: (UInt32, UInt32)] = [:]
        var ip: String?
        var p = ifap
        while let a = p {
            defer { p = a.pointee.ifa_next }
            let name = String(cString: a.pointee.ifa_name)
            guard name.hasPrefix("en"), let addr = a.pointee.ifa_addr else { continue }
            if addr.pointee.sa_family == UInt8(AF_LINK), let data = a.pointee.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                out[name] = (data.ifi_ibytes, data.ifi_obytes)
            } else if addr.pointee.sa_family == UInt8(AF_INET), ip == nil || name == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { ip = String(cString: host) }
            }
        }
        return (out, ip == nil ? nil : (out.keys.contains("en0") ? "en0" : out.keys.sorted().first), ip)
    }
}

// MARK: - Health

struct Health {
    var score = 100
    var reason = "Healthy"
    var tips: [Tip] = []
    struct Tip: Identifiable { let id = UUID(); let text: String; var action: String?; var target: Section? }
    var color: Color { score >= 80 ? Brand.accent : score >= 60 ? .orange : .red }

    static func evaluate(_ s: SystemSnapshot, topCPU: String?, topMemory: String?) -> Health {
        var penalties: [(Int, String)] = []
        var tips: [Tip] = []
        if s.cpuTotal >= 0.9 { penalties.append((25, "CPU saturated")); tips.append(.init(text: "The CPU is maxed out" + (topCPU.map { ". \($0) is using the most." } ?? "."))) }
        else if s.cpuTotal >= 0.75 { penalties.append((12, "CPU busy")) }
        if s.pressure >= 4 { penalties.append((25, "Memory pressure critical")) }
        else if s.pressure >= 2 { penalties.append((12, "Memory pressure")) }
        else if s.memTotal > 0, Double(s.memAvailable) / Double(s.memTotal) < 0.1 { penalties.append((10, "Low free memory")) }
        if s.swapUsed > 8_000_000_000 { penalties.append((20, "Swap heavy")) }
        else if s.swapUsed > 4_000_000_000 { penalties.append((10, "Swap in use")) }
        if s.swapUsed > 4_000_000_000 || s.pressure >= 2 {
            tips.append(.init(text: "Memory is overcommitted" + (topMemory.map { ". \($0) holds the most. Quit apps you aren't using." } ?? ". Quit apps you aren't using.")))
        }
        if s.diskTotal > 0 {
            let free = Double(s.diskTotal - s.diskUsed) / Double(s.diskTotal)
            if free < 0.08 { penalties.append((25, "Disk almost full")); tips.append(.init(text: "Free space is under 8%.", action: "Find what to clean", target: .overview)) }
            else if free < 0.15 { penalties.append((12, "Low disk space")); tips.append(.init(text: "Free space is under 15%.", action: "Find what to clean", target: .overview)) }
        }
        if s.readBps + s.writeBps > 250_000_000 { penalties.append((8, "Disk I/O busy")) }
        if let b = s.battery {
            if !b.onAC, b.level < 0.15 { penalties.append((10, "Battery low")); tips.append(.init(text: "Battery is under 15% and unplugged.")) }
            if let h = b.healthPercent, h < 80 { penalties.append((4, "Battery worn")) }
        }
        var h = Health()
        h.score = max(0, 100 - penalties.reduce(0) { $0 + $1.0 })
        h.reason = penalties.max { $0.0 < $1.0 }?.1 ?? "Healthy"
        h.tips = Array(tips.prefix(3))
        return h
    }
}

// MARK: - Monitor (lives only while the page is open)

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var snap = SystemSnapshot()
    @Published var groups: [ProcGroup] = []
    @Published var cpuHistory: [Double] = []
    @Published var readHistory: [Double] = []
    @Published var writeHistory: [Double] = []
    @Published var downHistory: [Double] = []
    @Published var upHistory: [Double] = []
    let machine: MachineInfo = Demo.enabled
        ? MachineInfo(model: "MacBook Pro", chip: "Apple M4 Pro", cores: 14, memory: 36 << 30, os: "macOS 26.1", uptime: 5 * 86_400 + 4 * 3600)
        : MachineInfo.read()
    private let sampler = SystemSampler()
    private let keep = 60

    var health: Health {
        Health.evaluate(snap, topCPU: groups.max { $0.cpu < $1.cpu }.map { "\($0.name) (\(Int($0.cpu))%)" },
                        topMemory: groups.first.map { "\($0.name) (\(ByteCountFormatter.string(fromByteCount: $0.rss, countStyle: .memory)))" })
    }

    /// Runs until the page goes away: the task is cancelled with the view, so a closed page costs nothing.
    func run() async {
        if Demo.enabled { loadDemo(); return }
        _ = sampler.sample()   // prime the counters; rates need two samples
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            snap = sampler.sample()
            push(&cpuHistory, snap.cpuTotal); push(&readHistory, snap.readBps); push(&writeHistory, snap.writeBps)
            push(&downHistory, snap.netDown); push(&upHistory, snap.netUp)
            if tick % 2 == 0 { groups = await Task.detached { Procs.scan().groups }.value }
            tick += 1
        }
    }

    /// Fixed, plausible numbers for screenshots.
    private func loadDemo() {
        var s = SystemSnapshot()
        s.cpuTotal = 0.38
        s.cores = [0.74, 0.52, 0.61, 0.44, 0.38, 0.29, 0.31, 0.22, 0.18, 0.41, 0.35, 0.27, 0.12, 0.09]
        s.load = (4.82, 4.11, 3.95)
        s.memTotal = 36 << 30; s.memUsed = Int64(21.4 * 1_073_741_824); s.memAvailable = Int64(11.2 * 1_073_741_824)
        s.swapTotal = 4 << 30; s.swapUsed = Int64(0.9 * 1_073_741_824); s.pressure = 1
        s.diskTotal = 994_600_000_000; s.diskUsed = 382_200_000_000
        s.readBps = 24_000_000; s.writeBps = 6_500_000
        s.netDown = 3_200_000; s.netUp = 410_000; s.netInterface = "en0"; s.netIP = "192.168.1.24"
        s.battery = BatteryInfo(level: 0.78, charging: false, onAC: false, minutesRemaining: 412, cycles: 187, healthPercent: 91, temperatureC: 31.4)
        snap = s
        func wave(_ base: Double, _ amp: Double, _ phase: Double) -> [Double] {
            (0..<60).map { i -> Double in
                let t = Double(i)
                let slow = sin(t / 5 + phase) * amp
                let fast = sin(t / 2.3) * amp / 3
                return max(0, base + slow + fast)
            }
        }
        cpuHistory = wave(0.38, 0.12, 0); readHistory = wave(22e6, 14e6, 1); writeHistory = wave(6e6, 4e6, 2)
        downHistory = wave(3e6, 2e6, 3); upHistory = wave(0.4e6, 0.3e6, 4)
        func g(_ n: String, _ procs: Int, _ gb: Double, _ cpu: Double, dev: Bool = false) -> ProcGroup { ProcGroup(name: n, pids: Array(0..<procs).map(Int32.init), rss: Int64(gb * 1_073_741_824), cpu: cpu, dev: dev) }
        groups = [g("Google Chrome", 41, 3.4, 22), g("Xcode", 9, 2.9, 31, dev: true), g("OrbStack", 3, 2.4, 18, dev: true), g("Cursor", 14, 1.8, 9, dev: true),
                  g("Slack", 8, 1.1, 3), g("claude", 4, 0.9, 6, dev: true), g("rust-analyzer", 1, 0.8, 11, dev: true), g("Figma", 6, 0.7, 2),
                  g("Spotify", 5, 0.5, 1), g("Notion", 5, 0.5, 1)]
    }

    private func push(_ a: inout [Double], _ v: Double) { a.append(v); if a.count > keep { a.removeFirst(a.count - keep) } }
}

// MARK: - Small views

struct Sparkline: View {
    let values: [Double]
    var ceiling: Double? = nil
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let top = max(ceiling ?? (values.max() ?? 1), 0.0001)
            let step = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0
            let pts = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: geo.size.height * (1 - CGFloat(min($0.element / top, 1)))) }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: geo.size.height)); p.addLine(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height)); p.closeSubpath()
                }.fill(color.opacity(0.15))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f); pts.dropFirst().forEach { p.addLine(to: $0) }
                }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }.frame(height: 34)
    }
}

struct Meter: View {
    let value: Double
    var color: Color = Brand.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(4, g.size.width * min(max(value, 0), 1)))
            }
        }.frame(height: 8)
    }
}

/// RAM is quoted in binary gigabytes (a "24 GB" Mac), unlike disk capacity which macOS quotes in decimal.
private func mem(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }

private func rate(_ bps: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .decimal) + "/s" }
private func load(_ v: Double, warn: Double = 0.7, bad: Double = 0.9) -> Color { v >= bad ? .red : v >= warn ? .orange : Brand.accent }

struct SystemCard<Content: View>: View {
    let title: String, symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading).panel(14)
    }
}

// MARK: - Page

struct SystemView: View {
    @EnvironmentObject var store: Store
    @StateObject private var m = SystemMonitor()
    @State private var sortByMemory = true
    @State private var pending: ProcGroup?

    var body: some View {
        let s = m.snap, h = m.health
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                machineLine
                hero(h)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], spacing: 14) {
                    cpu(s); memory(s); disk(s)
                    if let b = s.battery { power(b) }
                    network(s)
                }
                processes
            }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 62) }   // keep the first row clear of the glass toolbar
        .navigationTitle("System")
        .navigationSubtitle("Live · updates every 2 seconds")
        .task { await m.run() }
        .confirmationDialog("Quit \(pending?.name ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Quit \(pending?.pids.count ?? 0) processes", role: .destructive) {
                for p in pending?.pids ?? [] { kill(p, SIGTERM) }
                pending = nil
            }
        } message: { Text("Sends a normal quit request. Unsaved work in that app can be lost.") }
    }

    // MARK: Header and score

    private var machineLine: some View {
        let i = m.machine
        let up = Int(i.uptime), days = up / 86_400, hours = up % 86_400 / 3600
        return Text([i.model, i.chip, mem(i.memory) + " memory", i.os, "up \(days > 0 ? "\(days)d " : "")\(hours)h"].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.callout).foregroundStyle(.secondary)
    }

    private func hero(_ h: Health) -> some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Health").foregroundStyle(.secondary)
                Text("\(h.score)").font(.figure(76, .medium)).monospacedDigit().contentTransition(.numericText())
                    .animation(.smooth, value: h.score)
                HStack(spacing: 6) { Circle().fill(h.color).frame(width: 8, height: 8); Text(h.reason).fontWeight(.medium) }
            }.frame(minWidth: 150, alignment: .leading)
            Divider().frame(height: 80)
            VStack(alignment: .leading, spacing: 8) {
                if h.tips.isEmpty { Text("Nothing needs your attention.").foregroundStyle(.secondary) }
                ForEach(h.tips) { t in
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.text).fixedSize(horizontal: false, vertical: true)
                        if let a = t.action, let target = t.target { Button(a) { store.requestedSection = target }.controlSize(.small) }
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(20).panel(16)
    }

    // MARK: Cards

    private func cpu(_ s: SystemSnapshot) -> some View {
        SystemCard(title: "CPU", symbol: "cpu") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(s.cpuTotal * 100))%").font(.figure(30)).monospacedDigit()
                Spacer()
                Text(String(format: "Load %.2f  %.2f  %.2f", s.load.0, s.load.1, s.load.2)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Sparkline(values: m.cpuHistory, ceiling: 1, color: load(s.cpuTotal))
            // One bar per core: busy cores stand out at a glance.
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(s.cores.enumerated()), id: \.offset) { _, c in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 2).fill(load(c)).frame(height: max(2, 30 * c))
                    }.frame(height: 30)
                }
            }
            Text("\(s.cores.count) cores").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func memory(_ s: SystemSnapshot) -> some View {
        SystemCard(title: "Memory", symbol: "memorychip") {
            HStack(alignment: .firstTextBaseline) {
                Text(mem(s.memUsed)).font(.figure(30)).monospacedDigit()
                Text("of \(mem(s.memTotal))").foregroundStyle(.secondary)
                Spacer()
                Pill(text: s.pressure >= 4 ? "Critical" : s.pressure >= 2 ? "Under pressure" : "Healthy", color: s.pressure >= 4 ? .red : s.pressure >= 2 ? .orange : Brand.accent)
            }
            Meter(value: s.memFraction, color: load(s.memFraction, warn: 0.8, bad: 0.92))
            fact("Available", mem(s.memAvailable))
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text("Swap").foregroundStyle(.secondary); Spacer(); Text("\(mem(s.swapUsed)) of \(mem(s.swapTotal))").monospacedDigit() }.font(.callout)
                Meter(value: s.swapFraction, color: s.swapUsed > 8_000_000_000 ? .red : s.swapUsed > 4_000_000_000 ? .orange : Brand.accent)
            }
        }
    }

    private func disk(_ s: SystemSnapshot) -> some View {
        SystemCard(title: "Disk", symbol: "internaldrive") {
            let free = max(0, s.diskTotal - s.diskUsed)
            HStack(alignment: .firstTextBaseline) {
                Text(free.bytesString).font(.figure(30)).monospacedDigit()
                Text("free of \(s.diskTotal.bytesString)").foregroundStyle(.secondary)
            }
            Meter(value: s.diskTotal > 0 ? Double(s.diskUsed) / Double(s.diskTotal) : 0,
                  color: load(s.diskTotal > 0 ? Double(s.diskUsed) / Double(s.diskTotal) : 0, warn: 0.85, bad: 0.92))
            ioRow("Read", s.readBps, m.readHistory, .blue)
            ioRow("Write", s.writeBps, m.writeHistory, .orange)
        }
    }

    private func power(_ b: BatteryInfo) -> some View {
        SystemCard(title: "Power", symbol: b.charging ? "battery.100.bolt" : "battery.75") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(b.level * 100))%").font(.figure(30)).monospacedDigit()
                Text(b.charging ? "Charging" : b.onAC ? "Plugged in" : "On battery").foregroundStyle(.secondary)
                Spacer()
                if let mins = b.minutesRemaining { Text("\(mins / 60)h \(mins % 60)m \(b.charging ? "to full" : "left")").foregroundStyle(.secondary).monospacedDigit() }
            }
            Meter(value: b.level, color: b.level < 0.15 && !b.onAC ? .red : b.level < 0.3 && !b.onAC ? .orange : Brand.accent)
            if let h = b.healthPercent { fact("Battery health", "\(h)%") }
            if let c = b.cycles { fact("Charge cycles", "\(c)") }
            if let t = b.temperatureC { fact("Temperature", String(format: "%.1f °C", t)) }
        }
    }

    private func network(_ s: SystemSnapshot) -> some View {
        SystemCard(title: "Network", symbol: "arrow.up.arrow.down") {
            ioRow("Down", s.netDown, m.downHistory, .blue)
            ioRow("Up", s.netUp, m.upHistory, .orange)
            if let n = s.netInterface { fact("Interface", n + (s.netIP.map { " · \($0)" } ?? "")) }
        }
    }

    private func ioRow(_ label: String, _ bps: Double, _ history: [Double], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(rate(bps)).monospacedDigit() }.font(.callout)
            Sparkline(values: history, color: color)
        }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }.font(.callout)
    }

    // MARK: Processes

    private var processes: some View {
        let list = m.groups.sorted { sortByMemory ? $0.rss > $1.rss : $0.cpu > $1.cpu }.prefix(10)
        let maxV = Double(sortByMemory ? (list.first?.rss ?? 1) : Int64(list.first?.cpu ?? 1))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Top apps").font(.headline)
                Spacer()
                Picker("", selection: $sortByMemory) { Text("Memory").tag(true); Text("CPU").tag(false) }
                    .pickerStyle(.segmented).frame(width: 160).labelsHidden()
            }
            VStack(spacing: 0) {
                ForEach(Array(list)) { g in
                    HStack(spacing: 14) {
                        HStack(spacing: 6) { Text(g.name).fontWeight(.medium).lineLimit(1); if g.dev { Pill(text: "Dev tool", color: .blue) } }
                            .frame(width: 210, alignment: .leading)
                        Capsule().fill(.secondary.opacity(0.55)).frame(height: 5).frame(maxWidth: .infinity, alignment: .leading)
                            .scaleEffect(x: max(0.01, (sortByMemory ? Double(g.rss) : g.cpu) / max(maxV, 1)), anchor: .leading)
                        Text(String(format: "%.0f%%", g.cpu)).foregroundStyle(.secondary).monospacedDigit().frame(width: 52, alignment: .trailing)
                        Text(mem(g.rss)).monospacedDigit().frame(width: 76, alignment: .trailing)
                        Button("Quit") { pending = g }.controlSize(.small)
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                    if g.id != list.last?.id { Divider() }
                }
                if list.isEmpty { ProgressView().padding(20) }
            }.panel()
        }
    }
}
