//
//  SizeThresholdSlider.swift
//  CacheClear
//
//  A size distribution strip: every eligible repo is a dot placed by its size
//  (log scale) along a line, biggest to the right. Dragging the handle selects
//  everything at-or-above the cutoff — a fast way to grab "the big ones", then
//  the user fine-tunes by un-ticking individual rows.
//

import SwiftUI
import Foundation

struct SizeThresholdSlider: View {
    let repos: [ProjectRepo]
    var onThreshold: (UInt64) -> Void

    @State private var t: Double = 0   // 0 = include all, 1 = only the largest

    private var sizes: [UInt64] { repos.map(\.sizeBytes).filter { $0 > 0 } }
    private var logMin: Double { log10(Double(max(1, sizes.min() ?? 1))) }
    private var logMax: Double { log10(Double(max(1, sizes.max() ?? 1))) }
    private var span: Double { max(0.0001, logMax - logMin) }

    private func normX(_ bytes: UInt64) -> Double {
        (log10(Double(max(1, bytes))) - logMin) / span
    }
    private var cutoff: UInt64 { UInt64(pow(10, logMin + t * span)) }
    private var selectedCount: Int { repos.filter { $0.sizeBytes >= cutoff }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(LocalizedStringKey("slider.title"), systemImage: "slider.horizontal.below.square.filled.and.square")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(String(format: NSLocalizedString("slider.summary_format", comment: ""),
                            selectedCount, OffloadManager.formatBytes(cutoff)))
                    .font(.caption).fontWeight(.semibold).foregroundColor(.accentColor)
                    .monospacedDigit()
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
                        let selected = r.sizeBytes >= cutoff
                        let d = dotSize(r.sizeBytes)
                        Circle()
                            .fill(selected ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: d, height: d)
                            .position(x: min(w - 2, max(2, normX(r.sizeBytes) * w)), y: h / 2)
                    }
                }
            }
            .frame(height: 20)

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

    private func dotSize(_ bytes: UInt64) -> CGFloat {
        6 + CGFloat(normX(bytes)) * 7   // bigger repos → bigger dots
    }
}
