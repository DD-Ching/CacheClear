//
//  AppDelegate.swift
//  CacheClear
//
//  Created by 沒問題的 on 2026/1/25.
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    @Published var cacheSize: String = "..."
    @Published var lastCleared: String = ""

    private let customIconKey = "customIconPath"
    private var normalIcon: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupMenuBar()
        setupHotKey()
        refreshCacheSize()
        loadCustomIcon()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "trash.circle", accessibilityDescription: "CacheClear")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let sizeItem = NSMenuItem(title: "暫存: 計算中...", action: nil, keyEquivalent: "")
        sizeItem.tag = 100
        menu.addItem(sizeItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "清除暫存", action: #selector(clearCache), keyEquivalent: "")
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setupHotKey() {
        HotKeyManager.shared.onHotKeyPressed = { [weak self] in
            self?.clearCache()
        }
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
            let image = NSImage(systemSymbolName: "trash.circle", accessibilityDescription: "CacheClear")
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
        DispatchQueue.global(qos: .background).async { [weak self] in
            let size = self?.getCacheFolderSize() ?? 0
            let formatted = self?.formatBytes(size) ?? "0 KB"
            DispatchQueue.main.async {
                self?.cacheSize = formatted
                self?.updateMenuSize(formatted)
            }
        }
    }

    private func updateMenuSize(_ size: String) {
        if let menu = statusItem.menu,
           let item = menu.item(withTag: 100) {
            item.title = "暫存: \(size)"
        }
    }

    @objc func clearCache() {
        let fileManager = FileManager.default
        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var clearedSize: UInt64 = 0

            if let contents = try? fileManager.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for item in contents {
                    if let size = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                        clearedSize += UInt64(size)
                    }
                    try? fileManager.removeItem(at: item)
                }
            }

            DispatchQueue.main.async {
                self?.showNotification(clearedSize: clearedSize)
                self?.refreshCacheSize()
            }
        }
    }

    private func showNotification(clearedSize: UInt64) {
        let formatted = formatBytes(clearedSize)
        lastCleared = "已清除 \(formatted)"

        // Flash menu bar icon
        if let button = statusItem.button {
            let originalImage = normalIcon ?? button.image
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Cleared")

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                button.image = originalImage
            }
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let contentView = SettingsView()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "設定"
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func getCacheFolderSize() -> UInt64 {
        let fileManager = FileManager.default
        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return 0
        }

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
}
