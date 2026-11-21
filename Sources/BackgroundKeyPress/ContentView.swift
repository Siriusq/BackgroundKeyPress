import AppKit
import SwiftUI

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
                    Menu {
                        ForEach(controller.apps) { app in
                            Button {
                                controller.selectedPID = app.pid
                            } label: {
                                if app.pid == controller.selectedPID {
                                    Label(app.label, systemImage: "checkmark")
                                } else {
                                    Text(app.label)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(selectedTargetLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(controller.isRunning || controller.apps.isEmpty)
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

    private var selectedTargetLabel: String {
        controller.apps.first(where: { $0.pid == controller.selectedPID })?.label ?? "没有检测到有可见窗口的应用"
    }

    @ViewBuilder private func hotkeyRow(title: String, item: Hotkey, id: String) -> some View {
        HStack {
            Text("\(title)按键")
            Spacer()
            Text(item.name).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            Button(controller.recordingHotkey == id ? "按键中…" : "设置") { controller.recordingHotkey = id }
        }
    }

}
