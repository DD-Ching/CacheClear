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
    @State private var isRecording = false
    @State private var recordedShortcut: HotKeyManager.KeyShortcut?

    var body: some View {
        VStack(spacing: 20) {
            Text("全域快捷鍵")
                .font(.headline)

            VStack(spacing: 8) {
                Text("按下快捷鍵即可清除暫存")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ShortcutRecorderView(
                    isRecording: $isRecording,
                    currentShortcut: hotKeyManager.currentShortcut,
                    onShortcutRecorded: { shortcut in
                        hotKeyManager.register(shortcut: shortcut)
                    }
                )
            }

            Divider()

            HStack {
                Text("目前快捷鍵:")
                    .foregroundColor(.secondary)
                Text(hotKeyManager.currentShortcut?.displayString ?? "未設定")
                    .fontWeight(.medium)
            }
            .font(.caption)
        }
        .padding(24)
        .frame(width: 280, height: 180)
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
        button.title = "點擊設定"
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
            button.title = shortcut?.displayString ?? "點擊設定"
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
        button.title = "輸入快捷鍵..."

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
            button.title = "需要 ⌘/⌥/⌃"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.button.title = "輸入快捷鍵..."
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
