//
//  ContentView.swift
//  CacheClear
//
//  Created by 沒問題的 on 2026/1/25.
//

import SwiftUI

struct ContentView: View {
    @State private var cacheSize: String = "計算中..."
    @State private var isCleared: Bool = false
    @State private var isPressed: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            Text(isCleared ? "已清除!" : cacheSize)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)

            Button(action: clearCache) {
                Text("清除暫存")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isPressed ? .black : .white)
                    .frame(width: 100, height: 40)
                    .background(isPressed ? Color.white : Color.black)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                isPressed = pressing
            }, perform: {})
        }
        .frame(width: 180, height: 140)
        .onAppear {
            calculateCacheSize()
        }
    }

    private func calculateCacheSize() {
        DispatchQueue.global(qos: .background).async {
            let size = getCacheFolderSize()
            DispatchQueue.main.async {
                cacheSize = formatBytes(size)
            }
        }
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

    private func clearCache() {
        let fileManager = FileManager.default
        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if let contents = try? fileManager.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: nil) {
                for item in contents {
                    try? fileManager.removeItem(at: item)
                }
            }

            DispatchQueue.main.async {
                isCleared = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    isCleared = false
                    calculateCacheSize()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
