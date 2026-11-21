import AppKit
import ApplicationServices
import Combine
import CoreGraphics

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
            targetKeyName = KeyNameFormatter.keyName(event)
            recordingTargetKey = false
            status = "按键已设置为 \(targetKeyName)"
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let recordingHotkey {
            guard !mods.isEmpty else { return }
            let label = KeyNameFormatter.hotkeyName(event)
            let value = Hotkey(keyCode: event.keyCode, modifiers: mods, name: label)
            if recordingHotkey == "start" { startHotkey = value } else { stopHotkey = value }
            self.recordingHotkey = nil
            return
        }
        if event.keyCode == startHotkey.keyCode && mods == startHotkey.modifiers { start() }
        if event.keyCode == stopHotkey.keyCode && mods == stopHotkey.modifiers { stop() }
    }
}
