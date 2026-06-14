//
//  SizeThresholdSlider.swift
//  CacheClear
//
//  A size distribution strip: every eligible repo is a dot placed by its size
//  (log scale) along a line, biggest to the right. Three ways to use it, all
//  kept in sync with the scrollable list below:
//   • Drag the handle  → bulk-select everything at-or-above the cutoff.
//   • Hover a dot       → see which repo it is (name + size) and a highlight ring.
//   • Click a dot       → toggle just that one repo (select / deselect).
//  Dots are coloured by the repo's ACTUAL selection state, so ticking a row in
//  the list updates its dot, and clicking a dot updates its row.
//

import SwiftUI
import Foundation

struct SizeThresholdSlider: View {
    let repos: [ProjectRepo]
    var onThreshold: (UInt64) -> Void
    var onToggle: (String) -> Void

    @State private var t: Double = 0          // 0 = include all, 1 = only the largest
    @State private var hovered: String?

    private var sizes: [UInt64] { repos.map(\.sizeBytes).filter { $0 > 0 } }
    private var logMin: Double { log10(Double(max(1, sizes.min() ?? 1))) }
    private var logMax: Double { log10(Double(max(1, sizes.max() ?? 1))) }
    private var span: Double { max(0.0001, logMax - logMin) }

    private func normX(_ bytes: UInt64) -> Double {
        (log10(Double(max(1, bytes))) - logMin) / span
    }
    private var cutoff: UInt64 { UInt64(pow(10, logMin + t * span)) }
    private var selectedCount: Int { repos.filter(\.isSelected).count }
    private var hoveredRepo: ProjectRepo? { hovered.flatMap { id in repos.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(LocalizedStringKey("slider.title"),
                      systemImage: "slider.horizontal.below.square.filled.and.square")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if let r = hoveredRepo {
                    // Hovering a dot → show exactly which repo it is, immediately.
                    Text("\(r.name) · \(OffloadManager.formatBytes(r.sizeBytes))")
                        .font(.caption).fontWeight(.semibold)
                        .lineLimit(1)
                } else {
                    Text(String(format: NSLocalizedString("slider.selected_format", comment: ""), selectedCount))
                        .font(.caption).fontWeight(.semibold).foregroundColor(.accentColor)
                        .monospacedDigit()
                }
            }

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07)).frame(height: 4)
                    // highlight the selected (right) portion
                    Capsule().fill(Color.accentColor.opacity(0.18))
                        .frame(width: max(0, w * (1 - t)), height: 4)
                        .offset(x: w * t)
                    ForEach(repos) { r in
                        dot(r, w: w, h: h)
                    }
                }
            }
            .frame(height: 24)

            Slider(value: $t, in: 0...1)
                .controlSize(.small)
                .onChange(of: t) { _, _ in onThreshold(cutoff) }

            HStack {
                Text(LocalizedStringKey("slider.smaller")).font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(LocalizedStringKey("slider.bigger")).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func dot(_ r: ProjectRepo, w: CGFloat, h: CGFloat) -> some View {
        let d = dotSize(r.sizeBytes)
        let isHovered = hovered == r.id
        return ZStack {
            if isHovered {
                Circle().stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: d + 7, height: d + 7)
            }
            Circle()
                .fill(r.isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: d, height: d)
        }
        .frame(width: 24, height: 24)            // generous hit area for small dots
        .contentShape(Circle())
        .position(x: min(w - 2, max(2, normX(r.sizeBytes) * w)), y: h / 2)
        .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
        .onTapGesture { onToggle(r.id) }
        .help("\(r.name) · \(OffloadManager.formatBytes(r.sizeBytes))")
    }

    private func dotSize(_ bytes: UInt64) -> CGFloat {
        6 + CGFloat(normX(bytes)) * 7   // bigger repos → bigger dots
    }
}
