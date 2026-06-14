//
//  SupporterCard.swift
//  CacheClear
//
//  The calm, progress-first card shown inside OffloadView.busyOverlay during the
//  live scan and the live push, for FREE users only. It fills time the work
//  already needs — never an interruption. Top: a compact "working" row so it
//  reads as progress, not an ad. Middle: the swappable sponsor slot (default =
//  "support the author"; or the author's own promos/sponsor from SponsorProvider,
//  rotating). Tapping a sponsor ad opens its link; tapping the support card — or
//  the "support · hide ads" footer — opens the supporter sheet. Members never see
//  this; they get a one-line thanks in the overlay instead.
//

import SwiftUI
import AppKit
import Combine

struct SupporterCard: View {
    var onSupport: () -> Void

    @ObservedObject private var manager = OffloadManager.shared
    @ObservedObject private var sponsor = SponsorProvider.shared
    @State private var index = 0
    @State private var artScale: CGFloat = 1.0
    private let rotate = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var ad: SponsorAd {
        guard !sponsor.ads.isEmpty else { return .supportAuthor }
        return sponsor.ads[index % sponsor.ads.count]
    }

    /// The verb for the current phase: scanning vs uploading.
    private var actionKey: String {
        if case .scanning = manager.phase { return "support.card.scanning" }
        return "support.card.uploading"
    }

    /// The live detail line: the scanning status, or the repo being pushed.
    private var detailLine: String? {
        if !manager.statusLine.isEmpty { return manager.statusLine }
        if case .offloading(let r, _) = manager.phase { return r }
        return nil
    }

    var body: some View {
        VStack(spacing: 14) {
            // Compact "working" row — keeps this honest progress UI, not a banner.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringKey(actionKey)).font(.subheadline).fontWeight(.medium)
            }
            if let detailLine {
                Text(detailLine)
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Divider().frame(width: 220)

            // The swappable sponsor / support slot.
            Button(action: tapAd) {
                VStack(spacing: 8) {
                    artwork
                    Text(ad.headline).font(.headline).multilineTextAlignment(.center)
                    if let sub = ad.subhead, !sub.isEmpty {
                        Text(sub).font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(ad.id)
            .transition(.opacity)

            // For a real sponsor ad, offer the calm "support → hide ads" path.
            if !ad.isSupportAuthor {
                Button(action: onSupport) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart")
                        Text(LocalizedStringKey("sponsor.hide_with_support"))
                    }
                    .font(.caption2).foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(width: 340)
        .padding(20)
        .onReceive(rotate) { _ in
            guard sponsor.ads.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.5)) { index += 1 }
        }
        .onAppear { playArtPulseIfAllowed() }
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = ad.imageURL {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                ProgressView()
            }
            .frame(maxWidth: 280, maxHeight: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if let symbol = ad.symbol {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundColor(ad.isSupportAuthor ? .pink : .accentColor)
                .scaleEffect(artScale)
        }
    }

    private func tapAd() {
        if ad.isSupportAuthor {
            onSupport()
        } else if let url = ad.linkURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Gentle one-shot scale-in on the heart, only for the first few uploads ever.
    private func playArtPulseIfAllowed() {
        guard ad.isSupportAuthor, SupporterStore.shared.consumeHeartAnimation() else { return }
        withAnimation(.easeInOut(duration: 0.5)) { artScale = 1.06 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.35)) { artScale = 1.0 }
        }
    }
}
