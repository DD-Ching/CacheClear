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
    private let cacheFolderManager = CacheFolderManager.shared
    private let offloadMenuTag = 103
    private let restoreMenuTag = 104

    @Published var cacheSize: String = "..."
    @Published var lastCleared: String = ""

    private let customIconKey = "customIconPath"
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
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            guard service.status != .enabled else { return }
            do {
                try service.register()
            } catch {
                NSLog("Failed to enable launch at login: \(error)")
            }
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "trash.circle",
                accessibilityDescription: NSLocalizedString("accessibility.app_icon", comment: "")
            )
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        let sizeItem = NSMenuItem(
            title: NSLocalizedString("menu.cache_evaluating", comment: ""),
            action: nil,
            keyEquivalent: ""
        )
        sizeItem.tag = 100
        menu.addItem(sizeItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(
            title: NSLocalizedString("menu.clear_cache", comment: ""),
            action: #selector(clearCache),
            keyEquivalent: ""
        )
        clearItem.tag = 101
        menu.addItem(clearItem)

        let deepCleanItem = NSMenuItem(
            title: NSLocalizedString("menu.deep_clean", comment: ""),
            action: #selector(deepClean),
            keyEquivalent: ""
        )
        deepCleanItem.tag = deepCleanMenuTag
        menu.addItem(deepCleanItem)

        menu.addItem(NSMenuItem.separator())

        let offloadItem = NSMenuItem(
            title: NSLocalizedString("menu.offload", comment: ""),
            action: #selector(openOffloadWindow),
            keyEquivalent: ""
        )
        offloadItem.tag = offloadMenuTag
        menu.addItem(offloadItem)

        let restoreItem = NSMenuItem(
            title: NSLocalizedString("menu.restore", comment: ""),
            action: #selector(openRestoreWindow),
            keyEquivalent: ""
        )
        restoreItem.tag = restoreMenuTag
        menu.addItem(restoreItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("menu.settings", comment: ""),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: NSLocalizedString("menu.quit", comment: ""),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateClearMenuShortcut(HotKeyManager.shared.currentShortcut)
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

    // MARK: - Custom Icon

    func loadCustomIcon() {
        guard let path = UserDefaults.standard.string(forKey: customIconKey),
              let image = NSImage(contentsOfFile: path) else {
            return
        }
        setMenuBarIcon(image)
    }

    func setCustomIcon(from url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }

        // 複製圖片到 App Support 資料夾
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("CacheClear", isDirectory: true)

        try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)

        let iconPath = appFolder.appendingPathComponent("custom_icon.png")
        try? fileManager.removeItem(at: iconPath)
        try? fileManager.copyItem(at: url, to: iconPath)

        UserDefaults.standard.set(iconPath.path, forKey: customIconKey)
        setMenuBarIcon(image)
    }

    func resetToDefaultIcon() {
        UserDefaults.standard.removeObject(forKey: customIconKey)

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "trash.circle",
                accessibilityDescription: NSLocalizedString("accessibility.app_icon", comment: "")
            )
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            normalIcon = image
        }
    }

    private func setMenuBarIcon(_ image: NSImage) {
        if let button = statusItem.button {
            let resized = resizeImage(image, to: NSSize(width: 18, height: 18))
            resized.isTemplate = false // 保留原始顏色
            button.image = resized
            normalIcon = resized
        }
    }

    private func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    var hasCustomIcon: Bool {
        UserDefaults.standard.string(forKey: customIconKey) != nil
    }

    func refreshCacheSize() {
        if cacheOperationState == .clearing { return }
        if Thread.isMainThread {
            setCacheOperationState(.evaluating)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setCacheOperationState(.evaluating)
            }
        }

        let token = UUID()
        currentRefreshToken = token
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let size = self.withCacheFolderAccess { self.getCacheFolderSize(at: $0) }
            DispatchQueue.main.async {
                guard self.currentRefreshToken == token else { return }
                guard self.cacheOperationState == .evaluating else { return }
                if let size {
                    let formatted = self.formatBytes(size)
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

    private func keyEquivalentString(for keyCode: UInt32) -> String? {
        switch keyCode {
        case UInt32(kVK_ANSI_A): return "a"
        case UInt32(kVK_ANSI_B): return "b"
        case UInt32(kVK_ANSI_C): return "c"
        case UInt32(kVK_ANSI_D): return "d"
        case UInt32(kVK_ANSI_E): return "e"
        case UInt32(kVK_ANSI_F): return "f"
        case UInt32(kVK_ANSI_G): return "g"
        case UInt32(kVK_ANSI_H): return "h"
        case UInt32(kVK_ANSI_I): return "i"
        case UInt32(kVK_ANSI_J): return "j"
        case UInt32(kVK_ANSI_K): return "k"
        case UInt32(kVK_ANSI_L): return "l"
        case UInt32(kVK_ANSI_M): return "m"
        case UInt32(kVK_ANSI_N): return "n"
        case UInt32(kVK_ANSI_O): return "o"
        case UInt32(kVK_ANSI_P): return "p"
        case UInt32(kVK_ANSI_Q): return "q"
        case UInt32(kVK_ANSI_R): return "r"
        case UInt32(kVK_ANSI_S): return "s"
        case UInt32(kVK_ANSI_T): return "t"
        case UInt32(kVK_ANSI_U): return "u"
        case UInt32(kVK_ANSI_V): return "v"
        case UInt32(kVK_ANSI_W): return "w"
        case UInt32(kVK_ANSI_X): return "x"
        case UInt32(kVK_ANSI_Y): return "y"
        case UInt32(kVK_ANSI_Z): return "z"
        case UInt32(kVK_ANSI_0): return "0"
        case UInt32(kVK_ANSI_1): return "1"
        case UInt32(kVK_ANSI_2): return "2"
        case UInt32(kVK_ANSI_3): return "3"
        case UInt32(kVK_ANSI_4): return "4"
        case UInt32(kVK_ANSI_5): return "5"
        case UInt32(kVK_ANSI_6): return "6"
        case UInt32(kVK_ANSI_7): return "7"
        case UInt32(kVK_ANSI_8): return "8"
        case UInt32(kVK_ANSI_9): return "9"
        case UInt32(kVK_Space): return " "
        default:
            return nil
        }
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
        if cacheOperationState == .deepCleaning { return }
        DispatchQueue.main.async { [weak self] in
            self?.setCacheOperationState(.clearing)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let clearedSize = self.withCacheFolderAccess({ self.clearCacheContents(at: $0) }) else {
                DispatchQueue.main.async {
                    self.setCacheOperationState(.idle)
                    self.handleCacheFolderAccessFailure()
                }
                return
            }

            DispatchQueue.main.async {
                self.setCacheOperationState(.idle)
                self.showNotification(clearedSize: clearedSize)
                self.refreshCacheSize()
            }
        }
    }

    @objc func deepClean() {
        if cacheOperationState == .clearing || cacheOperationState == .deepCleaning { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("deep_clean.alert.title", comment: "")
        alert.informativeText = NSLocalizedString("deep_clean.alert.message", comment: "")
        alert.addButton(withTitle: NSLocalizedString("deep_clean.alert.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("deep_clean.alert.cancel", comment: ""))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        DispatchQueue.main.async { [weak self] in
            self?.setCacheOperationState(.deepCleaning)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let fileManager = FileManager.default
            let homeURL = fileManager.homeDirectoryForCurrentUser

            self.removeItemIfExists(homeURL.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
            self.runProcess("/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
            self.removeItemIfExists(homeURL.appendingPathComponent("Library/Developer/CoreSimulator"))
            self.removeItemIfExists(homeURL.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"))
            self.removeItemIfExists(homeURL.appendingPathComponent("Library/Developer/Xcode/Archives"))
            self.removeItemIfExists(homeURL.appendingPathComponent("Library/Caches/org.swift.swiftpm"))
            self.removeItemIfExists(homeURL.appendingPathComponent("Library/Caches/CocoaPods"))

            self.runShellCommand("yes | brew cleanup -s")
            self.runShellCommand("yes | brew autoremove")
            self.runShellCommand("npm cache clean --force")

            DispatchQueue.main.async {
                self.setCacheOperationState(.idle)
                self.flashMenuBarIcon(
                    systemSymbolName: "checkmark.circle.fill",
                    accessibilityKey: "accessibility.deep_clean_done"
                )
                self.refreshCacheSize()
            }
        }
    }

    private func showNotification(clearedSize: UInt64) {
        let formatted = formatBytes(clearedSize)
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
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
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
        Task { @MainActor in await OffloadManager.shared.refreshOffloads() }
    }

    private func withCacheFolderAccess<T>(_ handler: (URL) -> T) -> T? {
        if let result = cacheFolderManager.withSecurityScopedAccess(handler) {
            return result
        }
        return nil
    }

    private func clearCacheContents(at cachesURL: URL) -> UInt64 {
        let fileManager = FileManager.default
        var clearedSize: UInt64 = 0

        if let contents = try? fileManager.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for item in contents {
                if let size = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                    clearedSize += UInt64(size)
                }
                try? fileManager.removeItem(at: item)
            }
        }

        return clearedSize
    }

    private func getCacheFolderSize(at cachesURL: URL) -> UInt64 {
        let fileManager = FileManager.default
        var totalSize: UInt64 = 0

        if let enumerator = fileManager.enumerator(at: cachesURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += UInt64(fileSize)
                }
            }
        }

        return totalSize
    }

    private func handleCacheFolderAccessFailure() {
        if cacheFolderManager.selectedURL == nil {
            openSettings()
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("error.cache_folder_not_set", comment: "")
            alert.addButton(withTitle: NSLocalizedString("alert.ok", comment: ""))
            alert.runModal()
        }

        cacheSize = NSLocalizedString("menu.cache_size_unavailable", comment: "")
        updateMenuSize(cacheSize)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        } else if mb >= 1 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f KB", kb)
        }
    }

    private func flashMenuBarIcon(systemSymbolName: String, accessibilityKey: String) {
        if let button = statusItem.button {
            let originalImage = normalIcon ?? button.image
            button.image = NSImage(
                systemSymbolName: systemSymbolName,
                accessibilityDescription: NSLocalizedString(accessibilityKey, comment: "")
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                button.image = originalImage
            }
        }
    }

    private func removeItemIfExists(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            NSLog("Deep clean failed to remove \(url.path): \(error)")
        }
    }

    private func runProcess(_ launchPath: String, arguments: [String]) {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Deep clean failed to run \(launchPath): \(error)")
        }
    }

    private func runShellCommand(_ command: String) {
        let process = Process()
        process.launchPath = "/bin/zsh"
        process.arguments = ["-lc", command]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Deep clean failed to run shell command: \(command) error: \(error)")
        }
    }
}
