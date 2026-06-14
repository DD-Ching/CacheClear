//
//  SizeThresholdSlider.swift
//  CacheClear
//
//  A single draggable track: every eligible repo is a dot placed by its size
//  (log scale), biggest to the right, and a handle sits ON that same line. There
//  is no second control bar — the dots line IS the slider.
//   • Drag the handle → bulk-select everything at-or-above the handle.
//   • Hover a dot      → a floating label shows which repo it is (one source).
//   • Click a dot      → toggle just that one repo (select / deselect).
//  Dots are coloured by the repo's ACTUAL selection state, kept in sync with the
//  list below in both directions.
//

import SwiftUI
import Foundation

struct SizeThresholdSlider: View {
    let repos: [ProjectRepo]
    var onThreshold: (UInt64) -> Void
    var onToggle: (String) -> Void

    @State private var t: Double = 0          // 0 = include all, 1 = only the largest
    @State private var dragStartT: Double?
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
                Text(String(format: NSLocalizedString("slider.selected_format", comment: ""), selectedCount))
                    .font(.caption).fontWeight(.semibold).foregroundColor(.accentColor)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                let w = geo.size.width
                let trackY = geo.size.height - 12
                let hx = min(w - 9, max(9, w * t))
                ZStack(alignment: .topLeading) {
                    // base line
                    Capsule().fill(Color.primary.opacity(0.10))
                        .frame(width: w, height: 4).position(x: w / 2, y: trackY)
                    // selected (right of handle) highlight
                    Capsule().fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(0, w - hx), height: 4)
                        .position(x: hx + max(0, w - hx) / 2, y: trackY)

                    ForEach(repos) { r in dot(r, w: w, y: trackY) }

                    handle.position(x: hx, y: trackY)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    if dragStartT == nil { dragStartT = t }
                                    t = min(1, max(0, (dragStartT ?? t) + v.translation.width / w))
                                    onThreshold(cutoff)
                                }
                                .onEnded { _ in dragStartT = nil }
                        )

                    if let r = hoveredRepo {
                        hoverLabel(r)
                            .position(x: min(max(70, normX(r.sizeBytes) * w), w - 70), y: 9)
                    }
                }
            }
            .frame(height: 46)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var handle: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .contentShape(Circle().inset(by: -8))   // easy to grab
    }

    private func dot(_ r: ProjectRepo, w: CGFloat, y: CGFloat) -> some View {
        let d = dotSize(r.sizeBytes)
        let isHovered = hovered == r.id
        return ZStack {
            if isHovered {
                Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: d + 7, height: d + 7)
            }
            Circle()
                .fill(r.isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: d, height: d)
        }
        .frame(width: 24, height: 24)
        .contentShape(Circle())
        .position(x: min(w - 2, max(2, normX(r.sizeBytes) * w)), y: y)
        .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
        .onTapGesture { onToggle(r.id) }
    }

    private func hoverLabel(_ r: ProjectRepo) -> some View {
        Text("\(r.name) · \(OffloadManager.formatBytes(r.sizeBytes))")
            .font(.caption2).fontWeight(.medium)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
    }

    private func dotSize(_ bytes: UInt64) -> CGFloat {
        6 + CGFloat(normX(bytes)) * 7   // bigger repos → bigger dots
    }
}
