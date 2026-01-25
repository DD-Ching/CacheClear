//
//  CacheClearApp.swift
//  CacheClear
//
//  Created by 沒問題的 on 2026/1/25.
//

import SwiftUI

@main
struct CacheClearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu Bar App - 不顯示主視窗
        Settings {
            EmptyView()
        }
    }
}
