import AppKit
import SwiftUI
import CoreGraphics
import ApplicationServices

@main
struct BackgroundPressApp: App {
    @StateObject private var controller = PressController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(minWidth: 430)
        }
        .windowResizability(.contentSize)
    }
}

struct RunningApp: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    var id: pid_t { pid }
    var label: String { "\(name) (PID \(pid))" }
}

final class PressController: ObservableObject {
    @Published var apps: [RunningApp] = []
    @Published var selectedPID: pid_t?
    @Published var minInterval = UserDefaults.standard.object(forKey: "minIntervalMs") as? Double ?? 200.0 {
        didSet { UserDefaults.standard.set(minInterval, forKey: "minIntervalMs") }
    }
    @Published var maxInterval = UserDefaults.standard.object(forKey: "maxIntervalMs") as? Double ?? 400.0 {
        didSet { UserDefaults.standard.set(maxInterval, forKey: "maxIntervalMs") }
    }
    @Published var minimumIntervalText = ""
    @Published var maximumIntervalText = ""
    @Published private(set) var intervalValidationMessage: String?
    @Published private(set) var stopWhenTargetActivates = UserDefaults.standard.object(forKey: "stopWhenTargetActivates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(stopWhenTargetActivates, forKey: "stopWhenTargetActivates") }
    }
    @Published var status = "就绪"
    @Published var isRunning = false
    @Published var startHotkey = Hotkey(keyCode: 49, modifiers: [.command, .option], name: "⌥⌘Space")
    @Published var stopHotkey = Hotkey(keyCode: 53, modifiers: [.command, .option], name: "⌥⌘Esc")
    @Published var recordingHotkey: String?
    @Published var recordingTargetKey = false
    @Published var targetKeyCode = UInt16(UserDefaults.standard.object(forKey: "targetKeyCode") as? Int ?? 0x11) {
        didSet { UserDefaults.standard.set(Int(targetKeyCode), forKey: "targetKeyCode") }
    }
    @Published var targetKeyName = UserDefaults.standard.string(forKey: "targetKeyName") ?? "T" {
        didSet { UserDefaults.standard.set(targetKeyName, forKey: "targetKeyName") }
    }
    @Published var hasAccessibilityPermission = AXIsProcessTrusted()

    private var timer: DispatchWorkItem?
    private var activePID: pid_t?
    private var observer: NSObjectProtocol?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    init() {
        minimumIntervalText = NSNumber(value: minInterval).stringValue
        maximumIntervalText = NSNumber(value: maxInterval).stringValue
        updateIntervalValidation()
        refreshApps()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  self.isRunning, self.stopWhenTargetActivates,
                  app.processIdentifier == self.activePID else { return }
            self.stop(reason: "目标程序已切换到前台，已自动停止")
        }
        installHotkeyMonitor()
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        stop(reason: nil)
    }

    func refreshApps() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        let visibleWindowPIDs = Set(
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { window -> pid_t? in
                    guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                          let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
                          let number = window[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
                    return number.int32Value
                }
        )
        let current = NSWorkspace.shared.runningApplications
            .filter {
                !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                $0.activationPolicy == .regular && visibleWindowPIDs.contains($0.processIdentifier)
            }
            .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "未知程序") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        apps = current
        if let selectedPID, !current.contains(where: { $0.pid == selectedPID }) { self.selectedPID = nil }
        if selectedPID == nil { selectedPID = current.first?.pid }
    }

    func start() {
        guard intervalValidationMessage == nil else {
            status = intervalValidationMessage ?? "请检查按键间隔"
            return
        }
        guard hasAccessibilityPermission else {
            status = "请先授予辅助功能权限"
            return
        }
        guard let pid = selectedPID else { status = "请先选择目标程序"; return }
        guard !isRunning else { return }
        activePID = pid
        isRunning = true
        status = "正在向 PID \(pid) 发送 \(targetKeyName) 键"
        sendDown(pid: pid)
    }

    func updateMinimumInterval(from text: String) {
        guard let value = parsePositiveNumber(text) else {
            minimumIntervalInputIsValid = false
            updateIntervalValidation()
            return
        }
        minimumIntervalInputIsValid = true
        minInterval = value
        updateIntervalValidation()
    }

    func updateMaximumInterval(from text: String) {
        guard let value = parsePositiveNumber(text) else {
            maximumIntervalInputIsValid = false
            updateIntervalValidation()
            return
        }
        maximumIntervalInputIsValid = true
        maxInterval = value
        updateIntervalValidation()
    }

    func setStopWhenTargetActivates(_ enabled: Bool) {
        guard !isRunning else { return }
        stopWhenTargetActivates = enabled
    }

    func openAccessibilitySettings() {
        let currentSettings = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        let legacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(currentSettings) {
            NSWorkspace.shared.open(legacySettings)
        }
    }

    func stop(reason: String? = "已停止") {
        timer?.cancel()
        timer = nil
        if isRunning, let pid = activePID ?? selectedPID { sendUp(pid: pid) }
        activePID = nil
        isRunning = false
        if let reason { status = reason }
    }

    private var minimumIntervalInputIsValid = true
    private var maximumIntervalInputIsValid = true

    private func parsePositiveNumber(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        formatter.usesGroupingSeparator = false
        guard let number = formatter.number(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let value = number.doubleValue
        return value.isFinite && value > 0 ? value : nil
    }

    private func updateIntervalValidation() {
        if !minimumIntervalInputIsValid {
            intervalValidationMessage = "最小间隔必须是大于 0 的数字。"
        } else if !maximumIntervalInputIsValid {
            intervalValidationMessage = "最大间隔必须是大于 0 的数字。"
        } else if !minInterval.isFinite || minInterval <= 0 {
            intervalValidationMessage = "最小间隔必须是大于 0 的数字。"
        } else if !maxInterval.isFinite || maxInterval <= 0 {
            intervalValidationMessage = "最大间隔必须是大于 0 的数字。"
        } else if minInterval > maxInterval {
            intervalValidationMessage = "最小间隔不能大于最大间隔。"
        } else {
            intervalValidationMessage = nil
        }
    }

    private func scheduleNext(pid: pid_t) {
        guard isRunning else { return }
        let low = max(30, min(minInterval, maxInterval))
        let high = max(low, max(minInterval, maxInterval))
        let delay = max(0.005, Double.random(in: low...high) / 1000 - 0.025)
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.selectedPID == pid else { return }
            self.sendDown(pid: pid)
        }
        timer = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func sendDown(pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(targetKeyCode), keyDown: true) else { stop(reason: "无法创建按键事件"); return }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.postToPid(pid)
        // The selected key is held for a short, fixed 25 ms pulse.
        let up = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.sendUp(pid: pid)
            self.scheduleNext(pid: pid)
        }
        timer = up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: up)
    }

    private func sendUp(pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(targetKeyCode), keyDown: false) else { return }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.postToPid(pid)
    }

    private func installHotkeyMonitor() {
        // Global NSEvent monitors work when the app is in the background. macOS may require
        // Accessibility permission for global keyboard monitoring.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
            return event
        }
    }

    private func handleHotkey(_ event: NSEvent) {
        if recordingTargetKey {
            targetKeyCode = event.keyCode
            targetKeyName = ContentView.keyName(event)
            recordingTargetKey = false
            status = "按键已设置为 \(targetKeyName)"
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let recordingHotkey {
            guard !mods.isEmpty else { return }
            let label = ContentView.hotkeyName(event)
            let value = Hotkey(keyCode: event.keyCode, modifiers: mods, name: label)
            if recordingHotkey == "start" { startHotkey = value } else { stopHotkey = value }
            self.recordingHotkey = nil
            return
        }
        if event.keyCode == startHotkey.keyCode && mods == startHotkey.modifiers { start() }
        if event.keyCode == stopHotkey.keyCode && mods == stopHotkey.modifiers { stop() }
    }
}

struct Hotkey: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var name: String
}

struct DismissTextFieldFocusOnOutsideClick: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                guard let window = event.window else { return event }
                var hitView = window.contentView?.hitTest(event.locationInWindow)
                while let view = hitView {
                    if view is NSTextField { return event }
                    hitView = view.superview
                }
                window.makeFirstResponder(nil)
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: PressController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !controller.hasAccessibilityPermission {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("需要辅助功能权限").font(.headline)
                        Text("请在系统设置的“隐私与安全性 → 辅助功能”中启用本应用；如果列表里没有它，请点“+”并选择本应用，然后返回此窗口。应用会自动检测权限变化。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("打开系统设置") { controller.openAccessibilitySettings() }
                }
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            GroupBox {
                HStack(spacing: 10) {
                    Picker("运行中的程序", selection: $controller.selectedPID) {
                        if controller.apps.isEmpty {
                            Text("没有检测到有可见窗口的应用").tag(nil as pid_t?)
                        }
                        ForEach(controller.apps) { app in Text(app.label).tag(Optional(app.pid)) }
                    }.labelsHidden().frame(maxWidth: .infinity).disabled(controller.isRunning)
                    Button("刷新") { controller.refreshApps() }
                }.padding(.vertical, 4)
            } label: {
                sectionTitle("目标程序")
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("发送按键")
                        Spacer()
                        Text(controller.targetKeyName)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button(controller.recordingTargetKey ? "请按键…" : "选择") {
                            controller.recordingTargetKey = true
                        }
                    }
                    if controller.recordingTargetKey {
                        Text("请按下一个键；只记录单个按键，不包含修饰键。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                sectionTitle("按下的按键")
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最短").font(.system(size: 13, weight: .medium))
                        TextField("200", text: Binding(
                            get: { controller.minimumIntervalText },
                            set: { controller.minimumIntervalText = $0; controller.updateMinimumInterval(from: $0) }
                        ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 66)
                            .disabled(controller.isRunning)
                        Text("ms")
                        Text("最长").font(.system(size: 13, weight: .medium)).padding(.leading, 8)
                        TextField("400", text: Binding(
                            get: { controller.maximumIntervalText },
                            set: { controller.maximumIntervalText = $0; controller.updateMaximumInterval(from: $0) }
                        ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 66)
                            .disabled(controller.isRunning)
                        Text("ms")
                    }
                    Text("每次按键间随机选择间隔（至少 30 ms）").font(.caption).foregroundStyle(.secondary)
                    if let message = controller.intervalValidationMessage {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                }.padding(.vertical, 4)
            } label: {
                sectionTitle("按键间隔")
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    hotkeyRow(title: "开始", item: controller.startHotkey, id: "start")
                    hotkeyRow(title: "停止", item: controller.stopHotkey, id: "stop")
                    if controller.recordingHotkey != nil { Text("请按下组合键…（至少包含 ⌘、⌥、⌃、⇧ 之一）").font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 4)
            } label: {
                sectionTitle("快捷键")
            }
            GroupBox {
                Toggle("目标应用切换到前台时自动暂停", isOn: Binding(
                    get: { controller.stopWhenTargetActivates },
                    set: { controller.setStopWhenTargetActivates($0) }
                ))
                .disabled(controller.isRunning)
            } label: {
                sectionTitle("自动暂停")
            }
            HStack {
                Circle().fill(controller.isRunning ? .green : .gray).frame(width: 9, height: 9)
                Text(controller.status).font(.callout).lineLimit(1)
                Spacer()
                Button("开始") { controller.start() }.keyboardShortcut(.return)
                    .disabled(controller.isRunning || !controller.hasAccessibilityPermission || controller.intervalValidationMessage != nil)
                Button("停止") { controller.stop() }.keyboardShortcut(.escape).disabled(!controller.isRunning)
            }
            Text("全局快捷键和后台按键可能需要辅助功能权限。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .fixedSize(horizontal: false, vertical: true)
        .background(DismissTextFieldFocusOnOutsideClick())
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                controller.refreshApps()
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let appIcon = NSImage(contentsOf: iconURL) {
                NSApp.applicationIconImage = appIcon
            }
        }
        
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold))
    }

    @ViewBuilder private func hotkeyRow(title: String, item: Hotkey, id: String) -> some View {
        HStack {
            Text("\(title)按键")
            Spacer()
            Text(item.name).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            Button(controller.recordingHotkey == id ? "按键中…" : "设置") { controller.recordingHotkey = id }
        }
    }

    fileprivate static func hotkeyName(_ event: NSEvent) -> String {
        let m = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var value = ""
        if m.contains(.control) { value += "⌃" }; if m.contains(.option) { value += "⌥" }
        if m.contains(.shift) { value += "⇧" }; if m.contains(.command) { value += "⌘" }
        return value + (event.charactersIgnoringModifiers?.uppercased() ?? "Key\(event.keyCode)")
    }

    fileprivate static func keyName(_ event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Esc",
            0x72: "Insert", 0x73: "Home", 0x74: "Page Up", 0x75: "Forward Delete",
            0x77: "End", 0x79: "Page Down", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
            0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"
        ]
        if let name = specialKeys[event.keyCode] { return name }
        if let character = event.charactersIgnoringModifiers, !character.isEmpty {
            return character.uppercased()
        }
        return "Key \(event.keyCode)"
    }
}

