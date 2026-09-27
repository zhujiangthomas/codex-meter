import AppKit
import Combine
import SwiftUI

struct UsageWindow: Equatable {
    let usedPercent: Int
    let resetAt: Date?

    var remainingPercent: Int { max(0, 100 - usedPercent) }
}

struct DailyPoint: Identifiable, Equatable {
    let date: String
    let tokens: Int64
    var id: String { date }
}

struct UsageSnapshot: Equatable {
    let fiveHour: UsageWindow
    let weekly: UsageWindow
    let todayTokens: Int64?
    let dailyPoints: [DailyPoint]
    let plan: String
    let ordinaryUsageAllowed: Bool
    let todaySource: String
    let fetchedAt: Date
}

enum MeterError: LocalizedError {
    case codexNotFound
    case timeout
    case server(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "没有找到 Codex 命令行程序。请确认 ChatGPT 已安装，或安装 Codex CLI。"
        case .timeout:
            return "连接 Codex 超时，请稍后重试。"
        case .server(let message):
            return message
        case .malformedResponse:
            return "Codex 返回了无法识别的数据。"
        }
    }
}

final class AppServerCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var rateLimits: [String: Any]?
    private var usage: [String: Any]?
    private var errorMessage: String?
    private var didSignal = false
    let semaphore = DispatchSemaphore(value: 0)

    func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }

            if let id = (object["id"] as? NSNumber)?.intValue {
                if let error = object["error"] as? [String: Any], id == 2 || id == 3 {
                    errorMessage = error["message"] as? String ?? "Codex 数据读取失败。"
                } else if let result = object["result"] as? [String: Any] {
                    if id == 2 { rateLimits = result }
                    if id == 3 { usage = result }
                }
            }

            if !didSignal && (errorMessage != nil || (rateLimits != nil && usage != nil)) {
                didSignal = true
                semaphore.signal()
            }
        }
    }

    func result() -> (rateLimits: [String: Any], usage: [String: Any], error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (rateLimits ?? [:], usage ?? [:], errorMessage)
    }
}

enum CodexUsageClient {
    static func fetch() throws -> UsageSnapshot {
        let executable = try codexExecutable()
        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        let collector = AppServerCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.receive(data) }
        }

        try process.run()

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-meter","title":"Codex Meter","version":"1.0.0"},"capabilities":{"experimentalApi":true}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#,
            #"{"id":3,"method":"account/usage/read","params":{}}"#
        ].joined(separator: "\n") + "\n"
        stdin.fileHandleForWriting.write(Data(requests.utf8))

        let waitResult = collector.semaphore.wait(timeout: .now() + 20)
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        guard waitResult == .success else { throw MeterError.timeout }
        let response = collector.result()
        if let error = response.error { throw MeterError.server(error) }
        return try makeSnapshot(rateLimits: response.rateLimits, usage: response.usage)
    }

    private static func codexExecutable() throws -> String {
        let appURLs = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app")
        ].compactMap { $0 }
        let bundled = appURLs.flatMap { app in
            [
                app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path,
                app.appendingPathComponent("Contents/Resources/codex").path
            ]
        }
        let candidates = bundled + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw MeterError.codexNotFound
    }

    private static func makeSnapshot(rateLimits root: [String: Any], usage: [String: Any]) throws -> UsageSnapshot {
        guard let rate = root["rateLimits"] as? [String: Any],
              let primary = rate["primary"] as? [String: Any],
              let secondary = rate["secondary"] as? [String: Any]
        else { throw MeterError.malformedResponse }

        let fiveHour = window(from: primary)
        let weekly = window(from: secondary)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())

        var points: [DailyPoint] = (usage["dailyUsageBuckets"] as? [[String: Any]] ?? []).compactMap { item in
            guard let date = item["startDate"] as? String,
                  let number = item["tokens"] as? NSNumber else { return nil }
            return DailyPoint(date: date, tokens: number.int64Value)
        }

        let backendToday = points.first(where: { $0.date == today })?.tokens
        let localToday = localTokens(for: today)
        let todayTokens: Int64?
        let source: String
        if let backendToday, backendToday >= localToday {
            todayTokens = backendToday
            source = "账户统计"
        } else if localToday > 0 {
            todayTokens = localToday
            source = "本机实时"
        } else {
            todayTokens = backendToday
            source = backendToday == nil ? "等待汇总" : "账户统计"
        }

        if let todayTokens {
            if let index = points.firstIndex(where: { $0.date == today }) {
                points[index] = DailyPoint(date: today, tokens: max(points[index].tokens, todayTokens))
            } else {
                points.append(DailyPoint(date: today, tokens: todayTokens))
            }
        }
        points.sort { $0.date < $1.date }

        return UsageSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            todayTokens: todayTokens,
            dailyPoints: Array(points.suffix(7)),
            plan: (rate["planType"] as? String ?? "unknown").uppercased(),
            ordinaryUsageAllowed: root["ordinaryUsageAllowed"] as? Bool ?? true,
            todaySource: source,
            fetchedAt: Date()
        )
    }

    private static func window(from json: [String: Any]) -> UsageWindow {
        let used = (json["usedPercent"] as? NSNumber)?.intValue ?? 0
        let resetAt = (json["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(usedPercent: used, resetAt: resetAt)
    }

    private static func localTokens(for date: String) -> Int64 {
        let components = date.split(separator: "-").map(String.init)
        guard components.count == 3 else { return 0 }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let folder = URL(fileURLWithPath: home)
            .appendingPathComponent("sessions")
            .appendingPathComponent(components[0])
            .appendingPathComponent(components[1])
            .appendingPathComponent(components[2])
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for file in files where file.pathExtension == "jsonl" {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                guard line.contains(#""type":"token_usage_record""#),
                      let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "token_usage_record",
                      let payload = object["payload"] as? [String: Any],
                      let tokens = (payload["usage"] as? [String: Any])?["total_tokens"] as? NSNumber
                else { continue }
                total += tokens.int64Value
            }
        }
        return total
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var isCompact: Bool

    init() {
        isCompact = UserDefaults.standard.bool(forKey: "CodexMeterCompactMode")
    }

    var menuBarText: String {
        guard let snapshot else { return "—" }
        return "\(snapshot.fiveHour.remainingPercent)%"
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        Task {
            do {
                let newSnapshot = try await Task.detached(priority: .utility) {
                    try CodexUsageClient.fetch()
                }.value
                snapshot = newSnapshot
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    func toggleSize() {
        isCompact.toggle()
        UserDefaults.standard.set(isCompact, forKey: "CodexMeterCompactMode")
    }
}

struct QuotaCard: View {
    let title: String
    let subtitle: String
    let window: UsageWindow

    private var accent: Color {
        switch window.remainingPercent {
        case 0..<20: return .red
        case 20..<50: return .orange
        default: return .mint
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.09), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(window.remainingPercent) / 100)
                    .stroke(accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("已用 \(window.usedPercent)%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let resetAt = window.resetAt {
                    Text(compactResetText(resetAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func compactResetText(_ date: Date) -> String {
        let calendar = Calendar.current
        let prefix: String
        if calendar.isDateInToday(date) {
            prefix = "今天"
        } else if calendar.isDateInTomorrow(date) {
            prefix = "明天"
        } else {
            let day = DateFormatter()
            day.dateFormat = "M/d"
            prefix = day.string(from: date)
        }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        return "\(prefix) \(time.string(from: date)) 重置"
    }
}

struct DailyUsageCard: View {
    let tokens: Int64?
    let source: String
    let points: [DailyPoint]

    private var maximum: Double {
        max(1, Double(points.map(\.tokens).max() ?? 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("今日")
                        .font(.system(size: 13, weight: .semibold))
                    Text(source)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(tokens.map(compactTokens) ?? "—")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(points) { point in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(point.id == points.last?.id ? Color.accentColor : Color.accentColor.opacity(0.25))
                        .frame(height: max(4, 28 * Double(point.tokens) / maximum))
                        .help("\(point.date) · \(compactTokens(point.tokens)) tokens")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .bottom)
        }
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func compactTokens(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

struct CompactQuotaCard: View {
    let label: String
    let window: UsageWindow

    private var accent: Color {
        switch window.remainingPercent {
        case 0..<20: return .red
        case 20..<50: return .orange
        default: return .mint
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.09), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(window.remainingPercent) / 100)
                    .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 40, height: 40)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct MeterView: View {
    @ObservedObject var store: UsageStore
    private let timer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if store.isCompact {
                compactContent
            } else {
                expandedContent
            }
        }
        .padding(store.isCompact ? 6 : 11)
        .frame(width: store.isCompact ? 82 : 224)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .padding(8)
        .animation(.easeInOut(duration: 0.22), value: store.isCompact)
        .task { store.refresh() }
        .onReceive(timer) { _ in store.refresh() }
    }

    private var expandedContent: some View {
        VStack(spacing: 8) {
            header

            if let snapshot = store.snapshot {
                QuotaCard(title: "5 小时", subtitle: "剩余 \(snapshot.fiveHour.remainingPercent)%", window: snapshot.fiveHour)
                QuotaCard(title: "本周", subtitle: "剩余 \(snapshot.weekly.remainingPercent)%", window: snapshot.weekly)
                DailyUsageCard(tokens: snapshot.todayTokens, source: snapshot.todaySource, points: snapshot.dailyPoints)
            } else if store.isRefreshing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取 Codex 用量…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
    }

    private var compactContent: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [.cyan.opacity(0.9), .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                Button {
                    store.toggleSize()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .help("展开侧栏")
            }

            if let snapshot = store.snapshot {
                CompactQuotaCard(label: "5 小时", window: snapshot.fiveHour)
                CompactQuotaCard(label: "本周", window: snapshot.weekly)
                VStack(spacing: 2) {
                    Text("今日")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(compactTokens(snapshot.todayTokens))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 140)
            }

            HStack(spacing: 10) {
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .help("立即刷新")
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("退出")
            }
            .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.cyan.opacity(0.9), .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Meter")
                    .font(.system(size: 15, weight: .bold))
                if let snapshot = store.snapshot {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(snapshot.ordinaryUsageAllowed ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(snapshot.ordinaryUsageAllowed ? "正常 · \(snapshot.plan)" : "已用尽 · \(snapshot.plan)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                store.toggleSize()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("收起侧栏")
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("立即刷新")
        }
    }

    private var footer: some View {
        HStack {
            if let date = store.snapshot?.fetchedAt {
                Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("拖动侧栏移动")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Button("退出") { NSApplication.shared.terminate(nil) }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    private func compactTokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

@MainActor
final class CodexMeterDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        makeDesktopPanel()
        makeStatusItem()

        store.$snapshot.sink { [weak self] snapshot in
            guard let button = self?.statusItem?.button else { return }
            button.title = snapshot.map { " \($0.fiveHour.remainingPercent)%" } ?? " —"
            button.toolTip = "Codex 5 小时额度剩余"
        }
        .store(in: &subscriptions)

        store.$isCompact
            .dropFirst()
            .sink { [weak self] compact in
                self?.resizePanel(compact: compact, animated: true)
            }
            .store(in: &subscriptions)
    }

    private func makeDesktopPanel() {
        let rootView = MeterView(store: store)
        let hostingView = NSHostingView(rootView: rootView)
        let initialSize = store.isCompact ? NSSize(width: 98, height: 260) : NSSize(width: 240, height: 420)
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: -1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.setFrameAutosaveName("CodexMeterSidebarV1")

        if !panel.setFrameUsingName("CodexMeterSidebarV1"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - panel.frame.width - 10,
                y: visible.midY - panel.frame.height / 2
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func resizePanel(compact: Bool, animated: Bool) {
        guard let panel else { return }
        let newSize = compact ? NSSize(width: 98, height: 260) : NSSize(width: 240, height: 420)
        var frame = panel.frame
        let oldMaxX = frame.maxX
        let oldMidY = frame.midY
        let screen = panel.screen ?? NSScreen.main
        let anchorToRight = screen.map { frame.midX >= $0.visibleFrame.midX } ?? true
        frame.size = newSize
        frame.origin.y = oldMidY - newSize.height / 2
        if anchorToRight {
            frame.origin.x = oldMaxX - newSize.width
        }
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Codex Meter")
            button.imagePosition = .imageLeading
            button.title = " —"
            button.target = self
            button.action = #selector(toggleWidget)
        }
        statusItem = item
    }

    @objc private func toggleWidget() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }
}

#if SELF_TEST
@main
struct CodexMeterSelfTest {
    static func main() {
        do {
            let snapshot = try CodexUsageClient.fetch()
            print("fiveHourRemaining=\(snapshot.fiveHour.remainingPercent)")
            print("weeklyRemaining=\(snapshot.weekly.remainingPercent)")
            print("todayTokens=\(snapshot.todayTokens ?? -1)")
            print("todaySource=\(snapshot.todaySource)")
        } catch {
            fputs("self-test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#else
@main
struct CodexMeterApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = CodexMeterDelegate()
        application.delegate = delegate
        application.run()
    }
}
#endif
