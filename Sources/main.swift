import AppKit
import Charts
import Combine
import ServiceManagement
import SwiftUI

enum Provider: String, Codable, CaseIterable, Identifiable {
    case codex, claude, antigravity
    var id: Self { self }
    var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .antigravity: "Gemini · Antigravity"
        }
    }
    var color: Color {
        switch self {
        case .codex: Color(red: 0.14, green: 0.59, blue: 0.47)
        case .claude: Color(red: 0.85, green: 0.36, blue: 0.22)
        case .antigravity: Color(red: 0.32, green: 0.53, blue: 0.94)
        }
    }
}

struct Day: Decodable {
    let date: String
    let totalTokens: Int?
    let modelBreakdowns: [Model]?
}

struct Model: Decodable {
    let modelName: String
    let totalTokens: Int?
}

struct Quota: Codable {
    let label: String
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: String?

    var name: String {
        if windowMinutes == 300 { return "5 h" }
        if windowMinutes == 10080 { return "Week" }
        if let windowMinutes, windowMinutes >= 60 { return "\(windowMinutes / 60) h" }
        return "Quota"
    }

    var isActive: Bool { reset.map { $0 > .now } ?? true }

    var percentRemaining: Int {
        Int((100 - min(100, max(0, usedPercent))).rounded())
    }

    var reset: Date? {
        guard let resetsAt else { return nil }
        return ISO8601DateFormatter().date(from: resetsAt)
    }
}

struct Sample: Identifiable {
    let provider: Provider
    let day: Date
    let tokens: Int
    var id: String { "\(provider.rawValue)-\(day.timeIntervalSince1970)" }
}

private let reportingZone: TimeZone = .current
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = reportingZone
    return calendar
}()
private let dayParser: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = reportingZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()
private let english = Locale(identifier: "en_US")

func compact(_ tokens: Int) -> String {
    if tokens >= 1_000_000_000 {
        return (Double(tokens) / 1e9).formatted(.number.precision(.fractionLength(0...1)).locale(english)) + " B"
    }
    if tokens >= 1_000_000 {
        return (Double(tokens) / 1e6).formatted(.number.precision(.fractionLength(0...1)).locale(english)) + " M"
    }
    if tokens >= 1_000 {
        return (Double(tokens) / 1e3).formatted(.number.precision(.fractionLength(0...1)).locale(english)) + " K"
    }
    return tokens.formatted(.number.locale(english))
}

func displayDate(_ date: Date) -> String {
    Date.FormatStyle(date: .abbreviated, time: .omitted, locale: english,
                     calendar: calendar, timeZone: reportingZone).format(date)
}

@MainActor
final class Tracker: ObservableObject {
    @Published var history: [Provider: [Day]] = [:]
    @Published var quotas: [Provider: [Quota]] = [:]
    @Published var opensAtLogin = false
    @Published var quotaUpdated: [Provider: Date] = [:]
    @Published var failedHistory: Set<Provider> = []
    @Published var failedQuota: Set<Provider> = []
    @Published var loading = false
    @Published var updated: Date?
    @Published var range = 90
    @Published var selectedProvider: Provider?
    @Published var selected: Date?

    private struct QuotaReading: Codable {
        let sampledAt: Date
        let windows: [Quota]
    }

    private let quotaCacheKey = "Pulse.quotaReadings"

    init() {
        guard let data = UserDefaults.standard.data(forKey: quotaCacheKey),
              let cached = try? JSONDecoder().decode([Provider: QuotaReading].self, from: data) else { return }
        for (provider, reading) in cached where Date.now.timeIntervalSince(reading.sampledAt) < 7200 {
            quotas[provider] = reading.windows
            quotaUpdated[provider] = reading.sampledAt
        }
    }

    private func saveQuotaReadings() {
        let readings = quotas.compactMap { provider, windows in
            quotaUpdated[provider].map { (provider, QuotaReading(sampledAt: $0, windows: windows)) }
        }
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: readings)) {
            UserDefaults.standard.set(data, forKey: quotaCacheKey)
        }
    }

    var today: Date { calendar.startOfDay(for: .now) }
    var start: Date { calendar.date(byAdding: .day, value: 1 - range, to: today) ?? today }
    var end: Date { calendar.date(byAdding: .day, value: 1, to: today) ?? today }

    func rows(for provider: Provider) -> [Day] {
        history[provider, default: []].filter { row in
            guard let date = dayParser.date(from: row.date) else { return false }
            return date >= start && date < end
        }
    }

    var visibleProviders: [Provider] {
        selectedProvider.map { [$0] } ?? Provider.allCases
    }

    var points: [Sample] {
        visibleProviders.flatMap { provider in
            rows(for: provider).compactMap { row in
                guard let day = dayParser.date(from: row.date), let tokens = row.totalTokens else { return nil }
                return Sample(provider: provider, day: day, tokens: tokens)
            }
        }
    }

    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        let refreshInterval: TimeInterval = failedQuota.isEmpty ? 270 : 55
        if loading || (!force && updated.map({ Date.now.timeIntervalSince($0) < refreshInterval }) == true) {
            return false
        }
        loading = true
        failedHistory = []
        let ranges = Provider.allCases
        await withTaskGroup(of: Update.self) { group in
            for provider in ranges {
                group.addTask { .history(provider, await LocalHistory.shared.read(provider)) }
                group.addTask { .quota(provider, await LiveQuota.read(provider)) }
            }
            for await change in group {
                switch change {
                case let .history(provider, rows):
                    if let rows { history[provider] = rows }
                    else { failedHistory.insert(provider) }
                case let .quota(provider, windows):
                    if let windows, !windows.isEmpty {
                        quotas[provider] = windows
                        failedQuota.remove(provider)
                        quotaUpdated[provider] = .now
                        saveQuotaReadings()
                    } else {
                        failedQuota.insert(provider)
                    }
                }
            }
        }
        updated = .now
        loading = false
        return true
    }

    private enum Update: Sendable {
        case history(Provider, [Day]?)
        case quota(Provider, [Quota]?)
    }
}

struct Summary: View {
    @ObservedObject var tracker: Tracker
    let compactLayout: Bool
    let openWindow: () -> Void
    let setOpensAtLogin: (Bool) -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compactLayout ? 9 : 15) {
            HStack(alignment: compactLayout ? .center : .top, spacing: 10) {
                if !compactLayout {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
                        .frame(width: 44, height: 44).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pulse").font(compactLayout ? .headline : .system(size: 28, weight: .semibold))
                    if !compactLayout {
                        Text("Codex, Claude Code, and Gemini in Antigravity")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if tracker.loading { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await tracker.refresh(force: true) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh")
                .disabled(tracker.loading)
                if compactLayout { options }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Summary provider", selection: $tracker.selectedProvider) {
                        Text("All").tag(nil as Provider?)
                        ForEach(Provider.allCases) { provider in
                            Text(provider.name).tag(Optional(provider))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .onChange(of: tracker.selectedProvider) { _, _ in tracker.selected = nil }

                    Spacer(minLength: 4)
                    Picker("Period", selection: $tracker.range) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: compactLayout ? 172 : 192)
                    .onChange(of: tracker.range) { _, _ in tracker.selected = nil }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(tracker.selectedProvider?.name ?? "All providers")
                        .font(.caption).foregroundStyle(.secondary)
                    let complete = tracker.visibleProviders.allSatisfy { tracker.history[$0] != nil }
                    let partial = tracker.visibleProviders.contains { tracker.failedHistory.contains($0) }
                    if complete || (partial && !tracker.points.isEmpty) {
                        let total = tracker.points.reduce(0) { $0 + $1.tokens }
                        Text("\(partial ? "≥ " : "")\(total.formatted(.number.locale(english))) tokens")
                            .font(.headline).monospacedDigit().lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .help(partial ? "Some history is unavailable" : "Tokens recorded in this period")
                    } else {
                        Text(tracker.loading ? "Loading history…" : "Total unavailable")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                plot
                Text(dayCaption)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: compactLayout ? 9 : 14) {
                    ForEach(tracker.visibleProviders) { provider in
                        HStack(spacing: 5) {
                            Circle().fill(provider.color).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(compactLayout && provider == .antigravity ? "Gemini" : provider.name).lineLimit(1)
                            Text(legendValue(provider))
                                .fontWeight(.semibold).monospacedDigit().lineLimit(1)
                        }
                        .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(compactLayout ? 8 : 14)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: compactLayout ? 8 : 12))

            VStack(spacing: 0) {
                ForEach(tracker.visibleProviders) { provider in
                    if provider != tracker.visibleProviders.first { Divider() }
                    providerRow(provider)
                }
            }
            HStack {
                Text(compactLayout ? "Local tokens, including cache" : "Local history · Totals include cached tokens.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !compactLayout { options }
            }
        }
        .padding(compactLayout ? 13 : 22)
        .frame(width: compactLayout ? 462 : 650)
        .environment(\.locale, english)
        .environment(\.timeZone, reportingZone)
    }

    private var dayCaption: String {
        guard let day = tracker.selected else { return "Tokens per day" }
        let dayTotal = tracker.points.filter { $0.day == day }.reduce(0) { $0 + $1.tokens }
        return "\(displayDate(day)) · \(compact(dayTotal)) tokens"
    }

    private var options: some View {
        Menu {
            Button("Open in Window", action: openWindow)
            Toggle("Open at Login", isOn: Binding(
                get: { tracker.opensAtLogin }, set: setOpensAtLogin
            ))
            Divider()
            Button("Quit Pulse", action: quit)
        } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel("Options")
        }
        .menuStyle(.borderlessButton).frame(width: compactLayout ? 30 : 36)
    }

    private var plot: some View {
        Chart(tracker.points) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Tokens", point.tokens)
            )
            .foregroundStyle(by: .value("Provider", point.provider.name))
        }
        .chartXScale(domain: tracker.start ... tracker.end)
        .chartForegroundStyleScale(domain: Provider.allCases.map(\.name), range: Provider.allCases.map(\.color))
        .chartLegend(.hidden)
        .chartXAxis {
            let stride = switch tracker.range {
            case 90: compactLayout ? 18 : 14
            case 30: compactLayout ? 6 : 5
            default: compactLayout ? 2 : 1
            }
            AxisMarks(values: .stride(by: .day, count: stride)) { value in
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text("\(calendar.component(.day, from: date))/\(calendar.component(.month, from: date))")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Int.self) { Text(compact(number)) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    let rect = geometry[frame]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let location) = phase,
                               rect.contains(location),
                               let day: Date = proxy.value(atX: location.x - rect.minX) {
                                tracker.selected = min(tracker.today, calendar.startOfDay(for: day))
                            } else {
                                tracker.selected = nil
                            }
                        }
                }
            }
        }
        .frame(height: compactLayout ? 106 : 174)
        .accessibilityLabel("Daily token chart by provider")
        .overlay {
            if tracker.points.isEmpty {
                Text(tracker.loading ? "Reading local history…" : "No tokens recorded in this period")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
    }

    private func legendValue(_ provider: Provider) -> String {
        guard tracker.history[provider] != nil else { return "—" }
        let rows = tracker.points.filter { $0.provider == provider }
        guard !rows.isEmpty else { return "—" }
        return compact(rows.reduce(0) { $0 + $1.tokens })
    }

    private func providerRow(_ provider: Provider) -> some View {
        let rows = tracker.rows(for: provider)
        let models = Dictionary(grouping: rows.flatMap { $0.modelBreakdowns ?? [] }, by: \.modelName)
            .mapValues { $0.reduce(0) { $0 + ($1.totalTokens ?? 0) } }
            .sorted { $0.value > $1.value }
        let last = tracker.history[provider]?.compactMap { dayParser.date(from: $0.date) }.max()
        let active = tracker.quotas[provider, default: []].filter(\.isActive)
        let meters = Dictionary(grouping: active, by: \.name)
            .compactMapValues { $0.max { $0.usedPercent < $1.usedPercent } }
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(provider.color).frame(width: 3, height: 31)
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name).font(.subheadline.weight(.semibold))
                if tracker.failedHistory.contains(provider) {
                    Text(last == nil ? "History unavailable" : "Last available history")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let last {
                    let label = provider == .antigravity ? (compactLayout ? "Local tokens" : "Last local token record") : "Last record"
                    Text("\(label) · \(displayDate(last))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: compactLayout ? 135 : 160, alignment: .leading)
            if !models.isEmpty {
                Menu("Models") {
                    ForEach(models, id: \.key) { model in
                        Text("\(model.key) · \(compact(model.value))")
                    }
                }.controlSize(.small).fixedSize()
            }
            Spacer(minLength: 5)
            if !meters.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 10) {
                        ForEach(meters.keys.sorted(), id: \.self) { name in
                            if let quota = meters[name] {
                                VStack(alignment: .leading, spacing: 4) {
                                    let percent = quota.usedPercent.formatted(.number.precision(.fractionLength(0)))
                                    let label = compactLayout && quota.windowMinutes == 10080 ? "Week" : name
                                    Text("\(label) · \(percent)%")
                                        .font(.caption2).monospacedDigit().lineLimit(1)
                                        .accessibilityLabel("\(name), \(percent) percent used")
                                    ProgressView(value: min(100, max(0, quota.usedPercent)), total: 100)
                                        .tint(provider.color).accessibilityLabel("Quota \(name)")
                                }
                                .frame(width: compactLayout ? 64 : 95)
                                .help(quota.reset.map { "Resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Quota used")
                            }
                        }
                    }
                    if provider == .antigravity, let read = tracker.quotaUpdated[provider] {
                        let format = Date.FormatStyle(date: nil, time: .shortened, locale: english,
                                                      calendar: calendar, timeZone: reportingZone)
                        let time = calendar.isDateInToday(read) ? format.format(read) : displayDate(read)
                        Text(tracker.failedQuota.contains(provider) ? "Last reading · \(time)" : "Quota checked · \(time)")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if tracker.failedQuota.contains(provider) {
                        Text("Last known quota").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(tracker.loading ? "Checking quota…" : "Quota unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: compactLayout ? 44 : 49)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let tracker = Tracker()
    let popover = NSPopover()
    var popoverScreen: NSScreen?
    var item: NSStatusItem?
    var window: NSWindow?
    var timer: Timer?
    var menuQuotaObservation: AnyCancellable?
    var summarySelectionObservation: AnyCancellable?
    let providerMarks: [Provider: NSImage] = Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { provider in
        let symbol: String = switch provider {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "asterisk"
        case .antigravity: "sparkle"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: provider.name).map { (provider, $0) }
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        let button = item.button
        button?.target = self
        button?.action = #selector(toggle)
        button?.imagePosition = .imageOnly
        menuQuotaObservation = Publishers.CombineLatest3(tracker.$quotas, tracker.$failedQuota, tracker.$quotaUpdated)
            .sink { [weak self] quotas, failed, dates in
                self?.updateMenuQuotas(quotas, failed: failed, dates: dates)
            }
        summarySelectionObservation = tracker.$selectedProvider.dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizeSummaryPopover() }
            }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateMenuQuotas(self.tracker.quotas, failed: self.tracker.failedQuota, dates: self.tracker.quotaUpdated)
                await self.tracker.refresh()
            }
        }
        tracker.opensAtLogin = SMAppService.mainApp.status == .enabled
        if CommandLine.arguments.contains("--enable-login") {
            setOpensAtLogin(true)
            NSLog("Pulse: launch at login %ld", SMAppService.mainApp.status.rawValue)
        }
        popover.behavior = .transient
        popover.delegate = self
        if CommandLine.arguments.contains("--window") { showWindow() }
        if CommandLine.arguments.contains("--menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in self?.toggle() }
        }
        Task { await tracker.refresh() }
    }

    private func updateMenuQuotas(_ quotas: [Provider: [Quota]], failed: Set<Provider>, dates: [Provider: Date]) {
        guard let button = item?.button else { return }
        var labels = [String]()
        var details = [String]()
        for provider in Provider.allCases {
            let age = dates[provider].map { Date.now.timeIntervalSince($0) } ?? .infinity
            let active = age < 7200 ? quotas[provider, default: []].filter(\.isActive) : []
            if let limiting = active.max(by: { $0.usedPercent < $1.usedPercent }) {
                let cached = failed.contains(provider) || age > 600
                labels.append("\(limiting.percentRemaining)%\(cached ? "*" : "")")
                details.append("\(provider.name) · \(limiting.percentRemaining)% remaining (\(limiting.name))\(cached ? " · Last reading" : "")")
            } else {
                labels.append("–")
                details.append("\(provider.name) · Quota unavailable")
            }
        }
        let description = details.joined(separator: "\n")
        let image = quotaImage(labels)
        image.accessibilityDescription = description
        button.image = image
        button.toolTip = description
        button.setAccessibilityLabel(description)
        if CommandLine.arguments.contains("--verify-menu-quota") {
            NSLog("Pulse menu bar · %@ · width %.0f", labels.joined(separator: " | "), image.size.width)

        }
    }

    private func quotaImage(_ labels: [String]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let texts = labels.map { NSAttributedString(string: $0, attributes: attributes) }
        let marks = Provider.allCases.map { providerMarks[$0] }
        let iconSize: CGFloat = 11
        let innerGap: CGFloat = 2
        let groupGap: CGFloat = 6
        let height: CGFloat = 16
        let width = ceil(texts.reduce(0) { $0 + $1.size().width + iconSize + innerGap }
            + CGFloat(texts.count - 1) * groupGap)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (text, mark) in zip(texts, marks) {
                let bounds = NSRect(x: x, y: floor((height - iconSize) / 2),
                                    width: iconSize, height: iconSize)
                mark?.draw(in: bounds)
                let size = text.size()
                text.draw(at: NSPoint(x: x + iconSize + innerGap, y: floor((height - size.height) / 2)))
                x += iconSize + innerGap + size.width + groupGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func view(compact: Bool = false) -> Summary {
        Summary(
            tracker: tracker,
            compactLayout: compact,
            openWindow: { [weak self] in self?.showWindow() },
            setOpensAtLogin: { [weak self] enabled in self?.setOpensAtLogin(enabled) },
            quit: { NSApp.terminate(nil) }
        )
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled && (service.status == .notRegistered || service.status == .notFound) {
                try service.register()
            } else if !enabled && (service.status == .enabled || service.status == .requiresApproval) {
                try service.unregister()
            }
        } catch {
            NSLog("Pulse login item · %@", error.localizedDescription)
        }
        tracker.opensAtLogin = service.status == .enabled
        if enabled && service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showWindow() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: view()))
            created.title = "Pulse"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if popover.isShown { popover.performClose(nil) }
    }

    @objc func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item?.button, let buttonWindow = button.window else { return }
        let widthr = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: widthr.midX, y: widthr.midY))
                && widthr.midY >= $0.visibleFrame.maxY - 12
        } ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        popoverScreen = screen
        tracker.selected = nil
        tracker.opensAtLogin = SMAppService.mainApp.status == .enabled
        let width = min(462, visible.width - 24)
        let availableHeight = max(80, visible.height - 28)
        let content = view(compact: true).fixedSize(horizontal: true, vertical: true)
        let measuredHeight = NSHostingController(rootView: content).view.fittingSize.height
        let height = min(availableHeight, max(300, measuredHeight + 8))
        let fits = width >= 462 && height >= measuredHeight + 8
        let root = fits ? AnyView(content) : AnyView(ScrollView([.vertical, .horizontal]) {
            content
        }.scrollIndicators(.hidden))
        popover.contentViewController = NSHostingController(rootView: root)
        popover.contentSize = NSSize(width: width, height: height)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        Task { await tracker.refresh() }
    }

    private func resizeSummaryPopover() {
        guard popover.isShown, let screen = popoverScreen else { return }
        let content = view(compact: true).fixedSize(horizontal: true, vertical: true)
        let height = NSHostingController(rootView: content).view.fittingSize.height + 8
        popover.contentSize.height = min(max(80, screen.visibleFrame.height - 28), height)
        constrainSummaryPopover()
    }

    func popoverDidShow(_ notification: Notification) {
        constrainSummaryPopover()
    }

    private func constrainSummaryPopover() {
        guard let popoverWindow = popover.contentViewController?.view.window,
              let visible = popoverScreen?.visibleFrame.insetBy(dx: 4, dy: 4) else { return }
        let frame = popoverWindow.frame
        let x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        let y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        if frame.origin != NSPoint(x: x, y: y) {
            popoverWindow.setFrameOrigin(NSPoint(x: x, y: y))
        }
        if CommandLine.arguments.contains("--menu") {
            NSLog("Pulse popover %@ · Visible screen %@ · Fits %@ · Launch at login %ld",
                  NSStringFromRect(popoverWindow.frame), NSStringFromRect(visible),
                  String(visible.contains(popoverWindow.frame)), SMAppService.mainApp.status.rawValue)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(CommandLine.arguments.contains("--window") ? .regular : .accessory)
    app.run()
}
