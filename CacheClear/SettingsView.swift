//
//  SettingsView.swift
//  CacheClear
//
//  Created by 沒問題的 on 2026/1/25.
//

import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject private var hotKeyManager = HotKeyManager.shared
    @ObservedObject private var cacheFolderManager = CacheFolderManager.shared
    @ObservedObject private var offloadSettings = OffloadSettings.shared
    @ObservedObject private var supporterStore = SupporterStore.shared
    @State private var isRecording = false
    @State private var showSupporterSheet = false

    var body: some View {
        ScrollView {
        VStack(spacing: 16) {
            // 快捷鍵設定區
            GroupBox(LocalizedStringKey("settings.hotkey.group_title")) {
                VStack(spacing: 8) {
                    Text(LocalizedStringKey("settings.hotkey.subtitle"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ShortcutRecorderView(
                        isRecording: $isRecording,
                        currentShortcut: hotKeyManager.currentShortcut,
                        onShortcutRecorded: { shortcut in
                            hotKeyManager.register(shortcut: shortcut)
                        }
                    )

                    HStack {
                        Text(LocalizedStringKey("settings.hotkey.current_label"))
                            .foregroundColor(.secondary)
                        Text(hotKeyManager.currentShortcut?.displayString ?? NSLocalizedString("settings.hotkey.unset", comment: ""))
                            .fontWeight(.medium)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 8)
            }

            GroupBox(LocalizedStringKey("settings.cache_folder.group_title")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey("settings.cache_folder.subtitle"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text(LocalizedStringKey("settings.cache_folder.current_label"))
                            .foregroundColor(.secondary)
                        Text(cacheFolderManager.displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)

                    HStack {
                        Button(LocalizedStringKey("settings.cache_folder.choose_button")) {
                            cacheFolderManager.chooseFolder()
                        }
                        Button(LocalizedStringKey("settings.cache_folder.clear_button")) {
                            cacheFolderManager.clearSelection()
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            GroupBox(LocalizedStringKey("settings.offload.group_title")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalizedStringKey("settings.offload.subtitle"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Stepper(value: $offloadSettings.inactiveDays, in: 1...365) {
                        Text("\(NSLocalizedString("settings.offload.inactive_days", comment: "")): \(offloadSettings.inactiveDays)")
                            .font(.caption)
                    }

                    Toggle(isOn: $offloadSettings.autoCreatePrivate) {
                        Text(LocalizedStringKey("settings.offload.auto_create")).font(.caption)
                    }

                    Picker(selection: $offloadSettings.permanentDelete) {
                        Text(LocalizedStringKey("settings.offload.deletion_trash")).tag(false)
                        Text(LocalizedStringKey("settings.offload.deletion_permanent")).tag(true)
                    } label: {
                        Text(LocalizedStringKey("settings.offload.deletion_mode")).font(.caption)
                    }
                    .pickerStyle(.segmented)

                    Button(LocalizedStringKey("settings.offload.open_button")) {
                        AppDelegate.shared?.openOffloadWindow()
                    }
                }
                .padding(.vertical, 8)
            }

            GroupBox(LocalizedStringKey("support.settings.group_title")) {
                VStack(alignment: .leading, spacing: 8) {
                    if supporterStore.isSupporter {
                        Label(LocalizedStringKey("support.settings.member_status"), systemImage: "heart.fill")
                            .foregroundColor(.pink)
                            .font(.callout)
                    } else {
                        Text(LocalizedStringKey("support.settings.free_status"))
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(LocalizedStringKey("support.settings.support_button")) {
                            showSupporterSheet = true
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        }
        .padding(20)
        .frame(width: 380)
        }
        .frame(width: 380, height: 560)
        .sheet(isPresented: $showSupporterSheet) { SupporterSheet() }
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let currentShortcut: HotKeyManager.KeyShortcut?
    let onShortcutRecorded: (HotKeyManager.KeyShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onShortcutRecorded = onShortcutRecorded
        view.updateDisplay(shortcut: currentShortcut)
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.updateDisplay(shortcut: currentShortcut)
    }
}

class ShortcutRecorderNSView: NSView {
    private var button: NSButton!
    private var isRecording = false
    private var monitor: Any?
    var onShortcutRecorded: ((HotKeyManager.KeyShortcut) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupButton()
    }

    private func setupButton() {
        button = NSButton(frame: bounds)
        button.bezelStyle = .rounded
        button.title = NSLocalizedString("settings.hotkey.button_default", comment: "")
        button.target = self
        button.action = #selector(buttonClicked)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(button)

        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 150),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    func updateDisplay(shortcut: HotKeyManager.KeyShortcut?) {
        if !isRecording {
            button.title = shortcut?.displayString ?? NSLocalizedString("settings.hotkey.button_default", comment: "")
        }
    }

    @objc private func buttonClicked() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        button.title = NSLocalizedString("settings.hotkey.button_recording", comment: "")

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // 需要至少一個修飾鍵
        guard !modifiers.isEmpty else {
            button.title = NSLocalizedString("settings.hotkey.button_need_modifier", comment: "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.button.title = NSLocalizedString("settings.hotkey.button_recording", comment: "")
            }
            return
        }

        let carbonModifiers = cocoaToCarbonModifiers(modifiers)
        let shortcut = HotKeyManager.KeyShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers
        )

        stopRecording()
        button.title = shortcut.displayString
        onShortcutRecorded?(shortcut)
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: 150, height: 28)
    }
}

#Preview {
    SettingsView()
}
