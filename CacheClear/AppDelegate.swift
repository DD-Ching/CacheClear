//
//  AppDelegate.swift
//  CacheClear
//
//  Created by 沒問題的 on 2026/1/25.
//

import AppKit
import Carbon
import SwiftUI
import Combine
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSMenuDelegate {
    static var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var offloadWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let offloadMenuTag = 103
    private let restoreMenuTag = 104

    @Published var cacheSize: String = "..."
    @Published var lastCleared: String = ""

    private var normalIcon: NSImage?
    private var cacheOperationState: CacheOperationState = .idle
    private var currentRefreshToken: UUID?
    private let deepCleanMenuTag = 102

    private enum CacheOperationState {
        case idle
        case evaluating
        case clearing
        case deepCleaning
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        enableLaunchAtLogin()
        setupMenuBar()
        setupHotKey()
        refreshCacheSize()
    }

    private func enableLaunchAtLogin() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch {
            NSLog("Failed to enable launch at login: \(error)")
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "trash.circle",
                accessibilityDescription: NSLocalizedString("accessibility.app_icon", comment: "")
            )
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            normalIcon = image   // the stable base icon that flashes restore to
        }

        let menu = NSMenu()
        menu.delegate = self

        let sizeItem = NSMenuItem(
            title: NSLocalizedString("menu.cache_evaluating", comment: ""),
            action: nil,
            keyEquivalent: ""
        )
        sizeItem.tag = 100
        sizeItem.image = menuIcon("internaldrive")
        menu.addItem(sizeItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(
            title: NSLocalizedString("menu.clear_cache", comment: ""),
            action: #selector(clearCache),
            keyEquivalent: ""
        )
        clearItem.tag = 101
        clearItem.image = menuIcon("trash")
        menu.addItem(clearItem)

        let deepCleanItem = NSMenuItem(
            title: NSLocalizedString("menu.deep_clean", comment: ""),
            action: #selector(deepClean),
            keyEquivalent: ""
        )
        deepCleanItem.tag = deepCleanMenuTag
        deepCleanItem.image = menuIcon("sparkles")
        menu.addItem(deepCleanItem)

        menu.addItem(NSMenuItem.separator())

        let offloadItem = NSMenuItem(
            title: NSLocalizedString("menu.offload", comment: ""),
            action: #selector(openOffloadWindow),
            keyEquivalent: ""
        )
        offloadItem.tag = offloadMenuTag
        offloadItem.image = menuIcon("icloud.and.arrow.up")
        menu.addItem(offloadItem)

        let restoreItem = NSMenuItem(
            title: NSLocalizedString("menu.restore", comment: ""),
            action: #selector(openRestoreWindow),
            keyEquivalent: ""
        )
        restoreItem.tag = restoreMenuTag
        restoreItem.image = menuIcon("icloud.and.arrow.down")
        menu.addItem(restoreItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("menu.settings", comment: ""),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.image = menuIcon("gearshape")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: NSLocalizedString("menu.quit", comment: ""),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.image = menuIcon("power")
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateClearMenuShortcut(HotKeyManager.shared.currentShortcut)
    }

    /// A consistently-sized, template SF Symbol for menu items so every row reads
    /// uniformly and adapts to light/dark.
    private func menuIcon(_ symbol: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        image?.isTemplate = true
        return image
    }

    private func setupHotKey() {
        HotKeyManager.shared.onHotKeyPressed = { [weak self] in
            self?.clearCache()
        }

        HotKeyManager.shared.$currentShortcut
            .receive(on: RunLoop.main)
            .sink { [weak self] shortcut in
                self?.updateClearMenuShortcut(shortcut)
            }
            .store(in: &cancellables)
    }

    func refreshCacheSize() {
        if cacheOperationState == .clearing || cacheOperationState == .deepCleaning { return }
        setCacheOperationState(.evaluating)

        let token = UUID()
        currentRefreshToken = token
        Task { [weak self] in
            let size = await CacheService.shared.cacheSizeBytes()
            guard let self,
                  self.currentRefreshToken == token,
                  self.cacheOperationState == .evaluating else { return }
            if let size {
                let formatted = ByteFormat.string(size)
                self.cacheSize = formatted
                self.updateMenuSize(formatted)
            } else {
                let unavailable = NSLocalizedString("menu.cache_size_unavailable", comment: "")
                self.cacheSize = unavailable
                self.updateMenuSize(unavailable)
            }
            self.setCacheOperationState(.idle)
        }
    }

    private func updateMenuSize(_ size: String) {
        if let menu = statusItem.menu,
           let item = menu.item(withTag: 100) {
            item.title = String(format: NSLocalizedString("menu.cache_size_format", comment: ""), size)
        }
    }

    private func updateMenuStatusTitle(_ localizedKey: String) {
        if let menu = statusItem.menu,
           let item = menu.item(withTag: 100) {
            item.title = NSLocalizedString(localizedKey, comment: "")
        }
    }

    private func setClearMenuEnabled(_ isEnabled: Bool) {
        if let menu = statusItem.menu,
           let item = menu.item(withTag: 101) {
            item.isEnabled = isEnabled
        }
    }

    private func setDeepCleanMenuEnabled(_ isEnabled: Bool) {
        if let menu = statusItem.menu,
           let item = menu.item(withTag: deepCleanMenuTag) {
            item.isEnabled = isEnabled
        }
    }

    private func setCacheOperationState(_ state: CacheOperationState) {
        cacheOperationState = state
        switch state {
        case .idle:
            setClearMenuEnabled(true)
            setDeepCleanMenuEnabled(true)
            updateClearMenuSpinner(isSpinning: false)
            updateDeepCleanMenuSpinner(isSpinning: false)
        case .evaluating:
            updateMenuStatusTitle("menu.cache_evaluating")
            setClearMenuEnabled(true)
            setDeepCleanMenuEnabled(true)
            updateClearMenuSpinner(isSpinning: false)
            updateDeepCleanMenuSpinner(isSpinning: false)
        case .clearing:
            updateMenuStatusTitle("menu.cache_clearing")
            setClearMenuEnabled(false)
            setDeepCleanMenuEnabled(false)
            updateClearMenuSpinner(isSpinning: true)
            updateDeepCleanMenuSpinner(isSpinning: false)
        case .deepCleaning:
            updateMenuStatusTitle("menu.cache_deep_cleaning")
            setClearMenuEnabled(false)
            setDeepCleanMenuEnabled(false)
            updateClearMenuSpinner(isSpinning: false)
            updateDeepCleanMenuSpinner(isSpinning: true)
        }
    }

    private func updateClearMenuShortcut(_ shortcut: HotKeyManager.KeyShortcut?) {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: 101) else {
            return
        }

        guard let shortcut,
              let keyEquivalent = keyEquivalentString(for: shortcut.keyCode) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = modifierFlags(from: shortcut.modifiers)
    }

    private func updateClearMenuSpinner(isSpinning: Bool) {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: 101) else {
            return
        }
        updateMenuItemView(item, titleKey: "menu.clear_cache", showsSpinner: isSpinning)
    }

    private func updateDeepCleanMenuSpinner(isSpinning: Bool) {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: deepCleanMenuTag) else {
            return
        }
        updateMenuItemView(item, titleKey: "menu.deep_clean", showsSpinner: isSpinning)
    }

    private func updateMenuItemView(_ item: NSMenuItem, titleKey: String, showsSpinner: Bool) {
        let title = NSLocalizedString(titleKey, comment: "")
        if showsSpinner {
            item.view = makeMenuItemSpinnerView(title: title, isEnabled: item.isEnabled)
            item.title = title
        } else {
            item.view = nil
            item.title = title
        }
    }

    private func makeMenuItemSpinnerView(title: String, isEnabled: Bool) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        label.textColor = isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let stack = NSStackView(views: [label, spinner])
        stack.alignment = .centerY
        stack.spacing = 6

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    /// NSMenuItem key equivalent for the recorded hotkey — letters, digits and
    /// space only (reusing the shared keycode table); anything else shows no
    /// equivalent rather than a bogus glyph.
    private func keyEquivalentString(for keyCode: UInt32) -> String? {
        let s = keyCodeToString(keyCode)
        if s == "Space" { return " " }
        guard s.count == 1, let scalar = s.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        return s.lowercased()
    }

    private func modifierFlags(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    func menuWillOpen(_ menu: NSMenu) {
        switch cacheOperationState {
        case .clearing:
            updateMenuStatusTitle("menu.cache_clearing")
            return
        case .evaluating:
            updateMenuStatusTitle("menu.cache_evaluating")
            return
        case .deepCleaning:
            updateMenuStatusTitle("menu.cache_deep_cleaning")
            return
        case .idle:
            break
        }

        refreshCacheSize()
    }

    @objc func clearCache() {
        // The menu item is disabled while busy, but the global hotkey bypasses
        // menu enablement entirely — guard against every busy state.
        guard cacheOperationState == .idle || cacheOperationState == .evaluating else { return }
        setCacheOperationState(.clearing)

        Task { [weak self] in
            let clearedSize = await CacheService.shared.clearCache()
            guard let self else { return }
            self.setCacheOperationState(.idle)
            if let clearedSize {
                self.showNotification(clearedSize: clearedSize)
                self.refreshCacheSize()
            } else {
                self.handleCacheFolderAccessFailure()
            }
        }
    }

    @objc func deepClean() {
        guard cacheOperationState == .idle || cacheOperationState == .evaluating else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("deep_clean.alert.title", comment: "")
        alert.informativeText = NSLocalizedString("deep_clean.alert.message", comment: "")
        alert.addButton(withTitle: NSLocalizedString("deep_clean.alert.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("deep_clean.alert.cancel", comment: ""))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        // The modal spun the run loop — the hotkey could have started a clear in
        // the meantime, so the busy check must run again.
        guard cacheOperationState == .idle || cacheOperationState == .evaluating else { return }

        setCacheOperationState(.deepCleaning)

        Task { [weak self] in
            let outcome = await CacheService.shared.deepClean()
            guard let self else { return }
            self.setCacheOperationState(.idle)
            if outcome.failures > 0 {
                // Don't flash the success checkmark when steps failed.
                self.flashMenuBarIcon(
                    systemSymbolName: "exclamationmark.triangle.fill",
                    accessibilityKey: "accessibility.deep_clean_issues"
                )
            } else {
                self.flashMenuBarIcon(
                    systemSymbolName: "checkmark.circle.fill",
                    accessibilityKey: "accessibility.deep_clean_done"
                )
            }
            self.refreshCacheSize()
        }
    }

    private func showNotification(clearedSize: UInt64) {
        let formatted = ByteFormat.string(clearedSize)
        lastCleared = String(format: NSLocalizedString("notification.cleared_format", comment: ""), formatted)

        flashMenuBarIcon(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityKey: "accessibility.cleared_icon"
        )
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let contentView = SettingsView()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("settings.window.title", comment: "")
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openOffloadWindow() {
        if offloadWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("offload.window.title", comment: "")
            window.contentView = NSHostingView(rootView: OffloadView())
            window.center()
            window.isReleasedWhenClosed = false
            offloadWindow = window
        }
        offloadWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openRestoreWindow() {
        openOffloadWindow()
        OffloadManager.shared.requestRestoreTab()
    }

    private func handleCacheFolderAccessFailure() {
        if CacheFolderManager.shared.selectedURL == nil {
            openSettings()
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("error.cache_folder_not_set", comment: "")
            alert.addButton(withTitle: NSLocalizedString("alert.ok", comment: ""))
            alert.runModal()
        }

        cacheSize = NSLocalizedString("menu.cache_size_unavailable", comment: "")
        updateMenuSize(cacheSize)
    }

    private func flashMenuBarIcon(systemSymbolName: String, accessibilityKey: String) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: NSLocalizedString(accessibilityKey, comment: "")
        )
        // Restore to the stable base icon, NOT to whatever was on screen when
        // this flash began — two overlapping flashes must not freeze the
        // checkmark as the "original".
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            button.image = self?.normalIcon
        }
    }
}
