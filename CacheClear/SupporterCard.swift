//
//  SupporterCard.swift
//  CacheClear
//
//  The calm, progress-first card shown inside OffloadView.busyOverlay during the
//  live `git push` step, for FREE users only. It fills time the upload already
//  needs — never an interruption. Contents (kept deliberately skimmable in ~2s):
//  a real ProgressView, a single line that gently alternates between "Uploading…"
//  and a thank-you, the repo being pushed, and one quiet "Support the author ›"
//  footer. Supporters never see this — they get a one-line thanks in the overlay.
//

import SwiftUI
import Combine

struct SupporterCard: View {
    var onSupport: () -> Void

    @ObservedObject private var manager = OffloadManager.shared
    @State private var showThanks = false
    @State private var heartScale: CGFloat = 1.0
    private let rotate = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// The repo currently being pushed, read straight from the live phase.
    private var repoName: String? {
        if case .offloading(let r, _) = manager.phase { return r }
        return nil
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()

            // One short line, alternating Uploading… ⇄ thank-you (no long sentence).
            Text(LocalizedStringKey(showThanks ? "support.card.thanks" : "support.card.uploading"))
                .font(.headline)
                .id(showThanks)
                .transition(.opacity)

            if let repoName {
                Text(repoName)
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Divider().frame(width: 220)

            Button(action: onSupport) {
                HStack(spacing: 5) {
                    Image(systemName: "heart")
                        .foregroundColor(.pink.opacity(0.9))
                        .scaleEffect(heartScale)
                    Text(LocalizedStringKey("support.card.button"))
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .font(.callout)
                .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .frame(width: 320)
        .padding(20)
        .onReceive(rotate) { _ in
            withAnimation(.easeInOut(duration: 0.6)) { showThanks.toggle() }
        }
        .onAppear { playHeartIfAllowed() }
    }

    /// Gentle one-shot scale-in, but only for the first few uploads ever.
    private func playHeartIfAllowed() {
        guard SupporterStore.shared.consumeHeartAnimation() else { return }
        withAnimation(.easeInOut(duration: 0.5)) { heartScale = 1.06 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.35)) { heartScale = 1.0 }
        }
    }
}
