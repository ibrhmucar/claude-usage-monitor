// Claude Kullan\u{0131}m Takip - macOS Menu Bar Uygulamas\u{0131}
// v3.0 - Apple Design Language

import Cocoa
import SwiftUI
import Combine

// MARK: - Data Models
struct UsageData {
    var sessionUtilization: Double
    var sessionResetsAt: String
    var weeklyUtilization: Double
    var weeklyResetsAt: String
}

// MARK: - Monitor
class UsageMonitor: ObservableObject {
    @Published var sessionKey: String {
        didSet { UserDefaults.standard.set(sessionKey, forKey: "cum_sessionKey") }
    }
    @Published var orgId: String {
        didSet { UserDefaults.standard.set(orgId, forKey: "cum_orgId") }
    }
    @Published var refreshInterval: Int {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "cum_refreshInterval") }
    }
    @Published var usageData: UsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var retryAfterDate: Date?

    var isConfigured: Bool {
        let k = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = orgId.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.count > 10 && o.count > 10
    }

    init() {
        let key = UserDefaults.standard.string(forKey: "cum_sessionKey") ?? ""
        let org = UserDefaults.standard.string(forKey: "cum_orgId") ?? ""
        let interval = UserDefaults.standard.integer(forKey: "cum_refreshInterval")
        self.sessionKey = key
        self.orgId = org
        self.refreshInterval = interval == 0 ? 15 : interval
    }

    func fetchData() {
        guard isConfigured else { return }
        if let retryDate = retryAfterDate, Date() < retryDate {
            let remaining = Int(retryDate.timeIntervalSinceNow)
            DispatchQueue.main.async { self.errorMessage = "Rate limit - \(remaining / 60) dk sonra tekrar denenecek" }
            return
        }
        DispatchQueue.main.async { self.isLoading = true; self.errorMessage = nil }
        let org = orgId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://claude.ai/api/organizations/\(org)/usage") else {
            DispatchQueue.main.async { self.isLoading = false; self.errorMessage = "Ge\u{00E7}ersiz URL" }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        req.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        req.setValue("1.0.0", forHTTPHeaderField: "anthropic-client-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async { self?.isLoading = false; self?.lastUpdated = Date() }
            if let err = err {
                DispatchQueue.main.async { self?.errorMessage = "Ba\u{011F}lant\u{0131}: \(err.localizedDescription)" }
                return
            }
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 429 {
                let secs = Int(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? 120
                DispatchQueue.main.async {
                    self?.retryAfterDate = Date().addingTimeInterval(TimeInterval(secs))
                    self?.errorMessage = "Rate limit - \(secs / 60) dk bekleniyor"
                }
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                DispatchQueue.main.async { self?.errorMessage = "Session key ge\u{00E7}ersiz veya s\u{00FC}resi dolmu\u{015F}" }
                return
            }
            guard http.statusCode == 200, let data = data else {
                DispatchQueue.main.async { self?.errorMessage = "HTTP \(http.statusCode)" }
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self?.parseUsageResponse(json)
                }
            } catch {
                DispatchQueue.main.async { self?.errorMessage = "Veri okunamad\u{0131}" }
            }
        }.resume()
    }

    private func parseUsageResponse(_ json: [String: Any]) {
        if let fiveHour = json["five_hour"] as? [String: Any] {
            let sevenDay = json["seven_day"] as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                self.usageData = UsageData(
                    sessionUtilization: fiveHour["utilization"] as? Double ?? 0,
                    sessionResetsAt: fiveHour["resets_at"] as? String ?? "",
                    weeklyUtilization: sevenDay["utilization"] as? Double ?? 0,
                    weeklyResetsAt: sevenDay["resets_at"] as? String ?? ""
                )
                self.errorMessage = nil; self.retryAfterDate = nil
            }
            return
        }
        if let planLimits = json["plan_usage_limits"] as? [String: Any] {
            let s = planLimits["current_session"] as? [String: Any] ?? [:]
            let w = planLimits["weekly_limits"] as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                self.usageData = UsageData(
                    sessionUtilization: s["percentage_used"] as? Double ?? s["utilization"] as? Double ?? 0,
                    sessionResetsAt: s["resets_at"] as? String ?? "",
                    weeklyUtilization: w["percentage_used"] as? Double ?? w["utilization"] as? Double ?? 0,
                    weeklyResetsAt: w["resets_at"] as? String ?? ""
                )
                self.errorMessage = nil; self.retryAfterDate = nil
            }
            return
        }
        // Generic fallback
        DispatchQueue.main.async {
            var su = 0.0; var wu = 0.0; var found = false
            for (k, v) in json {
                if let d = v as? [String: Any], let u = d["utilization"] as? Double {
                    if k.contains("hour") || k.contains("session") { su = u; found = true }
                    else if k.contains("week") || k.contains("day") { wu = u; found = true }
                }
            }
            if found {
                self.usageData = UsageData(sessionUtilization: su, sessionResetsAt: "", weeklyUtilization: wu, weeklyResetsAt: "")
                self.errorMessage = nil
            } else {
                self.errorMessage = "Bilinmeyen veri format\u{0131}"
            }
        }
    }
}

// MARK: - NSTextField Wrappers
struct InputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isSecure: Bool = false

    func makeNSView(context: Context) -> NSTextField {
        let tf: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
        tf.placeholderString = placeholder
        tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tf.textColor = NSColor.labelColor
        tf.isEditable = true
        tf.isSelectable = true
        tf.isBordered = true
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.drawsBackground = true
        tf.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.1)
        tf.focusRingType = .exterior
        tf.delegate = context.coordinator
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        tf.cell?.usesSingleLineMode = true
        if let cell = tf.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = true
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InputField
        init(_ parent: InputField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField { parent.text = tf.stringValue }
        }
    }
}

// MARK: - Helpers
func formatResetTime(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = f.date(from: iso)
    if date == nil { f.formatOptions = [.withInternetDateTime]; date = f.date(from: iso) }
    guard let d = date else { return iso }
    let diff = d.timeIntervalSinceNow
    if diff <= 0 { return "\u{015F}imdi" }
    let mins = Int(diff) / 60
    if mins < 60 { return "\(mins) dk" }
    let hours = mins / 60
    let remMins = mins % 60
    if hours < 24 { return "\(hours) sa \(remMins) dk" }
    let days = hours / 24
    return "\(days) g\u{00FC}n \(hours % 24) sa"
}

func timeAgo(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "Az \u{00F6}nce" }
    let m = s / 60
    if m < 60 { return "\(m) dk \u{00F6}nce" }
    return "\(m / 60) saat \u{00F6}nce"
}

func colorForUsage(_ pct: Double) -> Color {
    if pct < 50 { return Color(red: 0.2, green: 0.78, blue: 0.35) }
    if pct < 80 { return Color(red: 1.0, green: 0.62, blue: 0.04) }
    return Color(red: 1.0, green: 0.27, blue: 0.23)
}

// MARK: - Usage Card (Apple-style)
struct UsageCardView: View {
    let title: String
    let subtitle: String
    let icon: String
    let utilization: Double
    let resetsAt: String

    var body: some View {
        let color = colorForUsage(utilization)
        VStack(spacing: 0) {
            // Top: icon + title + percentage
            HStack(alignment: .center) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(color)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "%.0f", utilization))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                Text("%")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(color.opacity(0.7))
                    .offset(y: 4)
            }
            .padding(.bottom, 10)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 6)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.8), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geo.size.width * CGFloat(min(utilization / 100.0, 1.0)), 4), height: 6)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: utilization)
                }
            }
            .frame(height: 6)
            .padding(.bottom, 8)

            // Bottom: subtitle + reset time
            HStack {
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if !resetsAt.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 8, weight: .medium))
                        Text(formatResetTime(resetsAt))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - Main View
struct MonitorView: View {
    @ObservedObject var monitor: UsageMonitor
    var onQuit: () -> Void
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().opacity(0.3)
            ScrollView {
                if !monitor.isConfigured || showSettings { settingsView }
                else { dashboardView }
            }
            Divider().opacity(0.3)
            footerView
        }
        .frame(width: 340)
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
        )
    }

    // MARK: Header
    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, Color(red: 1, green: 0.5, blue: 0)], startPoint: .top, endPoint: .bottom)
                )
            Text("Claude Kullan\u{0131}m Takip")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if monitor.isConfigured {
                Button(action: { withAnimation(.spring(response: 0.3)) { showSettings.toggle() } }) {
                    Image(systemName: showSettings ? "xmark.circle.fill" : "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: Dashboard
    private var dashboardView: some View {
        VStack(spacing: 10) {
            if let usage = monitor.usageData {
                UsageCardView(
                    title: "Oturum Limiti",
                    subtitle: "5 Saatlik Pencere",
                    icon: "bolt.fill",
                    utilization: usage.sessionUtilization,
                    resetsAt: usage.sessionResetsAt
                )

                UsageCardView(
                    title: "Haftal\u{0131}k Limit",
                    subtitle: "7 G\u{00FC}nl\u{00FC}k Pencere",
                    icon: "calendar",
                    utilization: usage.weeklyUtilization,
                    resetsAt: usage.weeklyResetsAt
                )
            } else if monitor.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Y\u{00FC}kleniyor...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(height: 140)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Veri Al\u{0131}namad\u{0131}")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(height: 120)
            }

            // Info bar
            VStack(spacing: 10) {
                if let t = monitor.lastUpdated {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Son G\u{00FC}ncelleme:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(timeAgo(t))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.8))
                        Spacer()
                        Button(action: { monitor.retryAfterDate = nil; monitor.fetchData() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .disabled(monitor.isLoading)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("G\u{00FC}ncelleme Aral\u{0131}\u{011F}\u{0131}:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("\(monitor.refreshInterval) dakika")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.8))
                    Spacer()
                }
            }
            .padding(.horizontal, 2)

            // Error
            if let err = monitor.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.9))
                        .lineLimit(2)
                    Spacer()
                }
            }

            // App icon + GitHub
            Button(action: {
                NSWorkspace.shared.open(URL(string: "https://github.com/ibrhmucar/claude-usage-monitor")!)
            }) {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange.opacity(0.5))
                    Text("Claude Usage Monitor")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.3))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Settings
    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Session Key
            VStack(alignment: .leading, spacing: 6) {
                Label("Session Key", systemImage: "key.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                InputField(text: $monitor.sessionKey, placeholder: "sk-ant-sid02-...", isSecure: true)
                    .frame(height: 24)
            }

            // Organization ID
            VStack(alignment: .leading, spacing: 6) {
                Label("Organization ID", systemImage: "building.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                InputField(text: $monitor.orgId, placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
                    .frame(height: 24)
            }

            // Instructions
            VStack(alignment: .leading, spacing: 5) {
                Label("Nas\u{0131}l Al\u{0131}n\u{0131}r", systemImage: "questionmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)

                Group {
                    Text("1. Chrome\u{2019}da claude.ai/settings/usage a\u{00E7}")
                    Text("2. F12 \u{2192} Network \u{2192} usage iste\u{011F}ine t\u{0131}kla")
                    Text("3. Cookie\u{2019}den sessionKey de\u{011F}erini kopyala")
                    Text("4. Org ID: claude.ai/settings/account sayfas\u{0131}nda")
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.06))
            )

            // Refresh interval
            VStack(alignment: .leading, spacing: 8) {
                Label("Yenileme S\u{0131}kl\u{0131}\u{011F}\u{0131}", systemImage: "timer")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $monitor.refreshInterval) {
                    Text("5").tag(5); Text("10").tag(10); Text("15").tag(15)
                    Text("20").tag(20); Text("25").tag(25); Text("30").tag(30)
                }
                .pickerStyle(.segmented)
                Text("Dakika cinsinden otomatik g\u{00FC}ncelleme aral\u{0131}\u{011F}\u{0131}")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Validation message
            if !monitor.isConfigured {
                let mk = monitor.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).count <= 10
                let mo = monitor.orgId.trimmingCharacters(in: .whitespacesAndNewlines).count <= 10
                let missing = [mk ? "Session Key" : nil, mo ? "Organization ID" : nil].compactMap { $0 }.joined(separator: " ve ")
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill").font(.system(size: 10))
                    Text("\(missing) girilmedi")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.orange)
            }

            // Save button
            Button(action: { doSave() }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Kaydet ve Kontrol Et")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(monitor.isConfigured ? Color.orange : Color.gray.opacity(0.5))
                )
            }
            .buttonStyle(.plain)
            .disabled(!monitor.isConfigured)
        }
        .padding(18)
        // Auto-save when both fields become valid
        .onChange(of: monitor.sessionKey) { _ in checkAutoSave() }
        .onChange(of: monitor.orgId) { _ in checkAutoSave() }
    }

    private func doSave() {
        monitor.retryAfterDate = nil
        monitor.fetchData()
        withAnimation(.spring(response: 0.3)) { showSettings = false }
    }

    private func checkAutoSave() {
        if monitor.isConfigured && !showSettings { return }
        if monitor.isConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if monitor.isConfigured {
                    doSave()
                }
            }
        }
    }

    // MARK: Footer
    private var footerView: some View {
        HStack {
            Button(action: {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                    Text("Kullan\u{0131}m Sayfas\u{0131}")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Spacer()

            Button(action: onQuit) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 10))
                    Text("\u{00C7}\u{0131}k\u{0131}\u{015F}")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

// MARK: - Visual Effect (Blur behind window - Apple style)
struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - KeyablePanel (keyboard input + shortcuts)
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var monitor: UsageMonitor!
    var timer: Timer?
    var cancellables = Set<AnyCancellable>()
    var globalClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupEditMenu()
        monitor = UsageMonitor()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.action = #selector(toggle); btn.target = self; updateButton()
        }

        let hostingView = NSHostingController(
            rootView: MonitorView(monitor: monitor, onQuit: { NSApp.terminate(nil) })
        )

        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingView
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // Round corners
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.masksToBounds = true

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.panel.orderOut(nil)
        }

        monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }.store(in: &cancellables)

        monitor.$refreshInterval.dropFirst().sink { [weak self] _ in
            self?.startTimer()
        }.store(in: &cancellables)

        startTimer()

        // İlk kurulumda ayarlar panelini otomatik aç
        if !monitor.isConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.toggle()
            }
        }
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(monitor.refreshInterval * 60), repeats: true) { [weak self] _ in
            self?.monitor.fetchData()
        }
        // Hemen fetch et
        monitor.fetchData()
    }

    func setupEditMenu() {
        let mainMenu = NSMenu()

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func updateButton() {
        guard let btn = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "gauge.with.needle.fill", accessibilityDescription: nil)
        img?.isTemplate = true
        btn.image = img
        btn.imagePosition = .imageLeading

        if !monitor.isConfigured {
            btn.title = " Ayarla"
        } else if monitor.isLoading {
            btn.title = " \u{2022}\u{2022}\u{2022}"
        } else if let u = monitor.usageData {
            let s = Int(u.sessionUtilization)
            let w = Int(u.weeklyUtilization)
            let warn = (u.sessionUtilization >= 80 || u.weeklyUtilization >= 80) ? " \u{26A0}\u{FE0F}" : ""
            btn.title = " S:\(s)% W:\(w)%\(warn)"
        } else {
            btn.title = " --"
        }
    }

    @objc func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            guard let btn = statusItem.button, let btnWindow = btn.window else { return }
            let btnRect = btn.convert(btn.bounds, to: nil)
            let screenRect = btnWindow.convertToScreen(btnRect)

            let pw: CGFloat = 340
            let ph: CGFloat = 460
            let x = screenRect.midX - pw / 2
            let y = screenRect.minY - ph - 6

            panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
