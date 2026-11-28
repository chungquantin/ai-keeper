import SwiftUI

/// Anything that runs without a window of its own (a cleanup rule, a maintenance task) reports here, so the sidebar can say what the app is doing.
@MainActor @Observable final class BackgroundTask: Identifiable {
    enum State { case running, done, failed }
    struct Line: Identifiable { let id = UUID(); let time: Date; let text: String }

    let id = UUID()
    let title: String
    let symbol: String
    let started = Date()
    private(set) var finished: Date?
    var state: State = .running
    var step = "Starting"
    var freed: Int64 = 0
    var log: [Line] = []

    init(title: String, symbol: String) { self.title = title; self.symbol = symbol; note("Started") }

    func note(_ text: String) { step = text; log.append(Line(time: Date(), text: text)) }
    func finish(freed: Int64 = 0, error: String? = nil) {
        self.freed = freed; finished = Date()
        if let error { state = .failed; note(error) } else { state = .done; note(freed > 0 ? "Done. \(freed.bytesString) freed." : "Done. Nothing needed clearing.") }
    }
    var elapsed: TimeInterval { (finished ?? Date()).timeIntervalSince(started) }
}

extension Store {
    var runningTasks: [BackgroundTask] { tasks.filter { $0.state == .running } }

    func beginTask(_ title: String, symbol: String) -> BackgroundTask {
        let t = BackgroundTask(title: title, symbol: symbol)
        tasks.insert(t, at: 0)
        if tasks.count > 30 { tasks.removeLast(tasks.count - 30) }
        return t
    }
}

/// Details for the sidebar popover: running tasks first, then what finished, each with its log.
struct BackgroundTaskList: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.tasks) { t in TaskRow(task: t); Divider() }
        }
    }
}

private struct TaskRow: View {
    let task: BackgroundTask
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    switch task.state {
                    case .running: ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 16)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent).frame(width: 16)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.reclaim).frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title).fontWeight(.medium).lineLimit(1)
                        Text(task.step).font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(task.state == .running ? task.elapsed.shortDuration : (task.finished ?? task.started).formatted(.relative(presentation: .numeric, unitsStyle: .narrow))).font(.bCaption2).foregroundStyle(.tertiary)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.bCaption2).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(task.log) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(l.time.formatted(date: .omitted, time: .standard)).foregroundStyle(.tertiary).monospacedDigit()
                            Text(l.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.font(.bCaption2)
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Brand.muted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }.padding(14)
    }
}
