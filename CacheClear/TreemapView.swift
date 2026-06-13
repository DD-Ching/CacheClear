//
//  TreemapView.swift
//  CacheClear
//
//  Renders the disk treemap. Block area ∝ on-disk bytes; colour = MapKind.
//

import SwiftUI
import AppKit

struct TreemapView: View {
    let items: [MapItem]
    let selected: Set<String>
    let sessionReclaimed: UInt64
    var onTap: (MapItem) -> Void

    @State private var hovered: String?

    private var total: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            legend
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(LocalizedStringKey("map.computing")).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let blocks = Squarify.layout(items, in: CGRect(origin: .zero, size: geo.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(blocks) { block in
                            blockView(block)
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: items)
                }
                .padding(4)
            }
        }
    }

    private func blockView(_ b: LaidOutBlock) -> some View {
        let w = max(0, b.rect.width)
        let h = max(0, b.rect.height)
        let showName = w >= 56 && h >= 24
        let showSize = h >= 38
        let item = b.item
        let isSel = item.kind == .repo && selected.contains(item.id)

        return ZStack {
            RoundedRectangle(cornerRadius: 4).fill(item.kind.fill)
            if isSel {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2.5)
            } else if hovered == item.id {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
            }
            if showName {
                VStack(spacing: 1) {
                    HStack(spacing: 3) {
                        if isSel { Image(systemName: "checkmark.seal.fill").font(.system(size: 9)) }
                        if item.kind == .repo && !item.repoSelectable {
                            Image(systemName: "lock.fill").font(.system(size: 8))
                        }
                        if item.kind == .junkAuto { Image(systemName: "trash").font(.system(size: 8)) }
                        Text(item.name).font(.system(size: 11, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if showSize {
                        Text(OffloadManager.formatBytes(item.bytes)).font(.system(size: 9)).opacity(0.9)
                    }
                }
                .foregroundColor(item.kind.textColor)
                .padding(3)
                .frame(width: w, height: h)
            }
        }
        .frame(width: w, height: h)
        .offset(x: b.rect.minX, y: b.rect.minY)
        .help("\(item.name) — \(OffloadManager.formatBytes(item.bytes))")
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .onTapGesture { onTap(item) }
        .contextMenu { contextMenu(item) }
    }

    @ViewBuilder
    private func contextMenu(_ item: MapItem) -> some View {
        Button(LocalizedStringKey("map.menu.reveal")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
        if item.kind == .junkAuto {
            Button(LocalizedStringKey("map.trash.confirm"), role: .destructive) { onTap(item) }
        } else if item.kind == .repo && item.repoSelectable {
            Button(LocalizedStringKey(selected.contains(item.id) ? "map.menu.deselect" : "map.menu.select")) {
                onTap(item)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(.green, "map.legend.repo")
            legendDot(.red, "map.legend.junk")
            legendDot(.orange, "map.legend.regen")
            legendDot(Color(nsColor: .systemGray), "map.legend.other")
            Spacer()
            if sessionReclaimed > 0 {
                Text(String(format: NSLocalizedString("map.reclaimed_format", comment: ""),
                            OffloadManager.formatBytes(sessionReclaimed)))
                    .font(.caption).foregroundColor(.green)
            }
            Text(String(format: NSLocalizedString("map.mapped_format", comment: ""),
                        items.count, OffloadManager.formatBytes(total)))
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func legendDot(_ color: Color, _ key: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color.opacity(0.8)).frame(width: 9, height: 9)
            Text(LocalizedStringKey(key)).font(.caption2).foregroundColor(.secondary)
        }
    }
}
