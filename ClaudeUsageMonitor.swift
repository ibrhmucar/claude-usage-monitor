// Claude Kullan\u{0131}m Takip - macOS Menu Bar Uygulamas\u{0131}
// Endpoint: https://claude.ai/api/organizations/{orgId}/usage
// Auth: Cookie sessionKey (same-origin)

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
            DispatchQueue.main.async {
                self.errorMessage = "Rate limit - \(remaining / 60) dk sonra tekrar denenecek"
            }
            return
        }

        DispatchQueue.main.async { self.isLoading = true; self.errorMessage = nil }

        let org = orgId.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = "https://claude.ai/api/organizations/\(org)/usage"
        guard let url = URL(string: urlStr) else {
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
                if let retryStr = http.value(forHTTPHeaderField: "retry-after"),
                   let retrySec = Int(retryStr) {
                    DispatchQueue.main.async {
                        self?.retryAfterDate = Date().addingTimeInterval(TimeInterval(retrySec))
                        self?.errorMessage = "Rate limit - \(retrySec / 60) dk bekleniyor"
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.retryAfterDate = Date().addingTimeInterval(120)
                        self?.errorMessage = "Rate limit - 2 dk bekleniyor"
                    }
                }
                return
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                DispatchQueue.main.async { self?.errorMessage = "Session key ge\u{00E7}ersiz veya s\u{00FC}resi dolmu\u{015F}" }
                return
            }

            guard http.statusCode == 200 else {
                var detail = ""
                if let data = data, let body = String(data: data, encoding: .utf8) {
                    detail = " - \(String(body.prefix(100)))"
                }
                DispatchQueue.main.async { self?.errorMessage = "HTTP \(http.statusCode)\(detail)" }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async { self?.errorMessage = "Bo\u{015F} yan\u{0131}t" }
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self?.parseUsageResponse(json)
                }
            } catch {
                let raw = String(data: data, encoding: .utf8) ?? "binary"
                DispatchQueue.main.async {
                    self?.errorMessage = "Parse hatas\u{0131}: \(String(raw.prefix(100)))"
                }
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
            let session = planLimits["current_session"] as? [String: Any] ?? [:]
            let weekly = planLimits["weekly_limits"] as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                self.usageData = UsageData(
                    sessionUtilization: session["percentage_used"] as? Double ?? session["utilization"] as? Double ?? 0,
                    sessionResetsAt: session["resets_at"] as? String ?? session["reset_time"] as? String ?? "",
                    weeklyUtilization: weekly["percentage_used"] as? Double ?? weekly["utilization"] as? Double ?? 0,
                    weeklyResetsAt: weekly["resets_at"] as? String ?? weekly["reset_time"] as? String ?? ""
                )
                self.errorMessage = nil; self.retryAfterDate = nil
            }
            return
        }

        let keys = json.keys.joined(separator: ", ")
        DispatchQueue.main.async {
            var sessionUtil = 0.0; var weeklyUtil = 0.0; var found = false
            for (key, value) in json {
                if let dict = value as? [String: Any], let util = dict["utilization"] as? Double {
                    if key.contains("hour") || key.contains("session") { sessionUtil = util; found = true }
                    else if key.contains("week") || key.contains("day") { weeklyUtil = util; found = true }
                }
            }
            if found {
                self.usageData = UsageData(sessionUtilization: sessionUtil, sessionResetsAt: "",
                                          weeklyUtilization: weeklyUtil, weeklyResetsAt: "")
                self.errorMessage = nil
            } else {
                self.errorMessage = "Bilinmeyen format. Anahtarlar: \(keys)"
            }
        }
    }
}

// MARK: - Views
struct MonitorView: View {
    @ObservedObject var monitor: UsageMonitor
    var onQuit: () -> Void
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
            if !monitor.isConfigured || showSettings { settingsView }
            else { dashboardView }
            footerView
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile").font(.system(size: 16, weight: .semibold)).foregroundColor(.orange)
            Text("Claude Kullan\u{0131}m Takip").font(.system(size: 14, weight: .bold, design: .rounded))
            Spacer()
            if monitor.isConfigured {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() } }) {
                    Image(systemName: showSettings ? "xmark.circle.fill" : "gearshape.fill")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var dashboardView: some View {
        VStack(spacing: 14) {
            if let usage = monitor.usageData {
                usageCard(title: "Oturum Limiti", subtitle: "5 Saatlik Pencere", icon: "bolt.fill",
                          utilization: usage.sessionUtilization, resetsAt: usage.sessionResetsAt)
                usageCard(title: "Haftal\u{0131}k Limit", subtitle: "7 G\u{00FC}nl\u{00FC}k Pencere", icon: "calendar",
                          utilization: usage.weeklyUtilization, resetsAt: usage.weeklyResetsAt)
            } else if monitor.isLoading {
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Y\u{00FC}kleniyor...").font(.system(size: 12)).foregroundColor(.secondary)
                }.frame(height: 120)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 24)).foregroundColor(.secondary)
                    Text("Veri Al\u{0131}namad\u{0131}").font(.system(size: 12)).foregroundColor(.secondary)
                }.frame(height: 100)
            }

            HStack {
                if let t = monitor.lastUpdated {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                    Text(timeAgo(t)).font(.system(size: 11))
                }
                Spacer()
                Button(action: { monitor.retryAfterDate = nil; monitor.fetchData() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).disabled(monitor.isLoading)
            }.foregroundColor(.secondary).padding(.horizontal, 16)

            if let err = monitor.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 10))
                    Text(err).font(.system(size: 10)).foregroundColor(.red).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 16)
            }
            Spacer().frame(height: 4)
        }.padding(.top, 12)
    }

    private func usageCard(title: String, subtitle: String, icon: String, utilization: Double, resetsAt: String) -> some View {
        let color = utilization < 50 ? Color.green : (utilization < 80 ? Color.orange : Color.red)
        return VStack(spacing: 8) {
            HStack {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(color)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "%.0f%%", utilization))
                    .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.15)).frame(height: 10)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(utilization / 100.0, 1.0)), height: 10)
                        .animation(.easeInOut(duration: 0.6), value: utilization)
                }
            }.frame(height: 10)
            HStack {
                Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                if !resetsAt.isEmpty {
                    Text("S\u{0131}f\u{0131}rlamaya Kalan: \(formatResetTime(resetsAt))")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor))
            .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1))
        .padding(.horizontal, 16)
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Session Key", systemImage: "key.fill").font(.system(size: 12, weight: .semibold))
                StableSecureField(text: $monitor.sessionKey, placeholder: "sk-ant-sid02-...")
                    .frame(height: 28)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Organization ID", systemImage: "building.2.fill").font(.system(size: 12, weight: .semibold))
                StableTextField(text: $monitor.orgId, placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
                    .frame(height: 28)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Nas\u{0131}l Al\u{0131}n\u{0131}r:").font(.system(size: 10, weight: .bold)).foregroundColor(.orange)
                Text("1. Chrome\u{2019}da claude.ai/settings/usage a\u{00E7}").font(.system(size: 10)).foregroundColor(.secondary)
                Text("2. F12 \u{2192} Network \u{2192} usage iste\u{011F}ine t\u{0131}kla").font(.system(size: 10)).foregroundColor(.secondary)
                Text("3. Cookie\u{2019}den: sessionKey=sk-ant-sid02-XXX").font(.system(size: 10)).foregroundColor(.secondary)
                Text("4. Org ID: claude.ai/settings/account sayfas\u{0131}nda").font(.system(size: 10)).foregroundColor(.secondary)
                Text("Sadece de\u{011F}erleri kopyala, etiketleri de\u{011F}il").font(.system(size: 10, weight: .medium)).foregroundColor(.green)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.05)))

            VStack(alignment: .leading, spacing: 6) {
                Label("Yenileme S\u{0131}kl\u{0131}\u{011F}\u{0131}", systemImage: "timer").font(.system(size: 12, weight: .semibold))
                Picker("", selection: $monitor.refreshInterval) {
                    Text("5 dk").tag(5); Text("10 dk").tag(10); Text("15 dk").tag(15)
                    Text("20 dk").tag(20); Text("25 dk").tag(25); Text("30 dk").tag(30)
                }.pickerStyle(.segmented)
            }

            if !monitor.isConfigured {
                let missingKey = monitor.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).count <= 10
                let missingOrg = monitor.orgId.trimmingCharacters(in: .whitespacesAndNewlines).count <= 10
                let missing = [missingKey ? "Session Key" : nil, missingOrg ? "Organization ID" : nil].compactMap { $0 }.joined(separator: " ve ")
                Text("\(missing) eksik").font(.system(size: 11, weight: .medium)).foregroundColor(.orange)
            }

            Button(action: { monitor.retryAfterDate = nil; monitor.fetchData(); withAnimation { showSettings = false } }) {
                HStack { Image(systemName: "checkmark.circle.fill"); Text("Kaydet ve Kontrol Et") }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(!monitor.isConfigured)
        }.padding(16)
    }

    private var footerView: some View {
        HStack {
            Button(action: { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }) {
                Label("claude.ai/usage", systemImage: "arrow.up.right.square").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundColor(.accentColor)
            Spacer()
            Button(action: onQuit) {
                Label("\u{00C7}\u{0131}k\u{0131}\u{015F}", systemImage: "power").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func timeAgo(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "Az \u{00D6}nce" }; let m = s / 60
        if m < 60 { return "\(m) dk \u{00F6}nce" }; return "\(m/60) saat \u{00F6}nce"
    }

    private func formatResetTime(_ iso: String) -> String {
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
        if hours < 24 { return "\(hours)s \(remMins)dk" }
        let days = hours / 24
        return "\(days)g \(hours % 24)s"
    }
}

// MARK: - Stable NSTextField Wrappers (fixes popover input issues on some macOS versions)
struct StableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isSecure: Bool = false

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.isEditable = true
        tf.isSelectable = true
        tf.isBordered = true
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.delegate = context.coordinator
        tf.focusRingType = .exterior
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: StableTextField
        init(_ parent: StableTextField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            }
        }
    }
}

struct StableSecureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let tf = NSSecureTextField()
        tf.placeholderString = placeholder
        tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.isEditable = true
        tf.isSelectable = true
        tf.isBordered = true
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.delegate = context.coordinator
        tf.focusRingType = .exterior
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        return tf
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: StableSecureField
        init(_ parent: StableSecureField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var monitor: UsageMonitor!
    var timer: Timer?
    var cancellables = Set<AnyCancellable>()
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        monitor = UsageMonitor()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.action = #selector(toggle); btn.target = self; updateButton()
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MonitorView(monitor: monitor, onQuit: { NSApp.terminate(nil) })
        )

        monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }.store(in: &cancellables)

        monitor.$refreshInterval.dropFirst().sink { [weak self] _ in
            self?.startTimer()
        }.store(in: &cancellables)

        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(monitor.refreshInterval * 60), repeats: true) { [weak self] _ in
            self?.monitor.fetchData()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.monitor.fetchData()
        }
    }

    func updateButton() {
        guard let btn = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "gauge.with.needle.fill", accessibilityDescription: nil)
        img?.isTemplate = true; btn.image = img; btn.imagePosition = .imageLeading

        if !monitor.isConfigured { btn.title = " Ayarla" }
        else if monitor.isLoading { btn.title = " ..." }
        else if let u = monitor.usageData {
            let s = Int(u.sessionUtilization); let w = Int(u.weeklyUtilization)
            let flag = u.sessionUtilization >= 80 || u.weeklyUtilization >= 80 ? " \u{26A0}" : ""
            btn.title = " S:\(s)% W:\(w)%\(flag)"
        } else { btn.title = " --" }
    }

    @objc func toggle() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Activate app so text fields can receive input
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            // Ensure popover window becomes key window for keyboard input
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
                window.makeFirstResponder(popover.contentViewController?.view)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
