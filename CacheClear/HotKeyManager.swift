//
//  HotKeyManager.swift
//  CacheClear
//
//  Created by 沒問題的 on 2026/1/25.
//

import Carbon
import AppKit
import Combine

class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    @Published var currentShortcut: KeyShortcut?
    @Published var isRecording = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onHotKeyPressed: (() -> Void)?

    private let shortcutKey = "savedShortcut"

    init() {
        installHandlerIfNeeded()
        loadShortcut()
    }

    struct KeyShortcut: Codable, Equatable {
        let keyCode: UInt32
        let modifiers: UInt32

        var displayString: String {
            var parts: [String] = []
            if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
            if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
            if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
            if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
            parts.append(keyCodeToString(keyCode))
            return parts.joined()
        }
    }

    /// The Carbon event handler is installed exactly ONCE for the app's lifetime.
    /// Installing it inside register() stacked a fresh handler on every shortcut
    /// change and none were ever removed.
    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            HotKeyManager.shared.onHotKeyPressed?()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandler)
    }

    func register(shortcut: KeyShortcut) {
        unregister()
        currentShortcut = shortcut
        saveShortcut()

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4343_4C52) // "CCLR"
        hotKeyID.id = 1

        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func saveShortcut() {
        guard let shortcut = currentShortcut else { return }
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: shortcutKey)
        }
    }

    private func loadShortcut() {
        guard let data = UserDefaults.standard.data(forKey: shortcutKey),
              let shortcut = try? JSONDecoder().decode(KeyShortcut.self, from: data) else {
            // Default: ⌘⇧C
            let defaultShortcut = KeyShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey))
            register(shortcut: defaultShortcut)
            return
        }
        register(shortcut: shortcut)
    }
}

func keyCodeToString(_ keyCode: UInt32) -> String {
    let mapping: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "⌫", UInt32(kVK_Return): "↵",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
    return mapping[keyCode] ?? "?"
}

func cocoaToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    return carbon
}
