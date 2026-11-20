import AppKit
import SwiftUI
import CoreGraphics

@main
struct BackgroundPressApp: App {
    @StateObject private var controller = PressController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(minWidth: 520, minHeight: 440)
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
    @Published var status = "就绪"
    @Published var isRunning = false
    @Published var startHotkey = Hotkey(keyCode: 49, modifiers: [.command, .option], name: "⌥⌘Space")
    @Published var stopHotkey = Hotkey(keyCode: 53, modifiers: [.command, .option], name: "⌥⌘Esc")
    @Published var recordingHotkey: String?

    private var timer: DispatchWorkItem?
    private var activePID: pid_t?
    private var observer: NSObjectProtocol?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let tKey: CGKeyCode = 0x11

    init() {
        refreshApps()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  self.isRunning, app.processIdentifier == self.activePID else { return }
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
        guard let pid = selectedPID else { status = "请先选择目标程序"; return }
        guard !isRunning else { return }
        activePID = pid
        isRunning = true
        status = "正在向 PID \(pid) 发送 T 键"
        sendDown(pid: pid)
    }

    func stop(reason: String? = "已停止") {
        timer?.cancel()
        timer = nil
        if isRunning, let pid = activePID ?? selectedPID { sendUp(pid: pid) }
        activePID = nil
        isRunning = false
        if let reason { status = reason }
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
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: tKey, keyDown: true) else { stop(reason: "无法创建按键事件"); return }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.postToPid(pid)
        // T is held for a short, fixed 25 ms pulse; the configured interval is between key-downs.
        let up = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.sendUp(pid: pid)
            self.scheduleNext(pid: pid)
        }
        timer = up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: up)
    }

    private func sendUp(pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: tKey, keyDown: false) else { return }
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

struct ContentView: View {
    @ObservedObject var controller: PressController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("后台 T 键助手").font(.largeTitle.bold())
                Text("向选中的后台程序发送 T 键按下指令").foregroundStyle(.secondary)
            }
            GroupBox("目标程序") {
                HStack(spacing: 10) {
                    Picker("运行中的程序", selection: $controller.selectedPID) {
                        if controller.apps.isEmpty {
                            Text("没有检测到有可见窗口的应用").tag(nil as pid_t?)
                        }
                        ForEach(controller.apps) { app in Text(app.label).tag(Optional(app.pid)) }
                    }.labelsHidden().frame(maxWidth: .infinity).disabled(controller.isRunning)
                    Button("刷新") { controller.refreshApps() }
                }.padding(.vertical, 4)
            }
            GroupBox("按键间隔") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最短")
                        TextField("200", value: $controller.minInterval, format: .number).frame(width: 76)
                        Text("ms")
                        Text("最长").padding(.leading, 12)
                        TextField("400", value: $controller.maxInterval, format: .number).frame(width: 76)
                        Text("ms")
                    }
                    Text("每次按键间随机选择间隔（至少 30 ms）").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            GroupBox("快捷键") {
                VStack(alignment: .leading, spacing: 8) {
                    hotkeyRow(title: "开始", item: controller.startHotkey, id: "start")
                    hotkeyRow(title: "停止", item: controller.stopHotkey, id: "stop")
                    if controller.recordingHotkey != nil { Text("请按下组合键…（至少包含 ⌘、⌥、⌃、⇧ 之一）").font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 4)
            }
            HStack {
                Circle().fill(controller.isRunning ? .green : .gray).frame(width: 9, height: 9)
                Text(controller.status).font(.callout).lineLimit(1)
                Spacer()
                Button("开始") { controller.start() }.keyboardShortcut(.return).disabled(controller.isRunning)
                Button("停止") { controller.stop() }.keyboardShortcut(.escape).disabled(!controller.isRunning)
            }
            Text("应用切换到前台时会自动停止。全局快捷键可能需要在系统设置中授予辅助功能权限。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                controller.refreshApps()
            }
        }
        .onAppear { NSApp.setActivationPolicy(.regular) }
        
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
}

