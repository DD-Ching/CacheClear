//
//  SupporterSheet.swift
//  CacheClear
//
//  The "support the author" sheet, styled like a modern, warm membership screen:
//  a gradient hero with a heart medallion, then a card body. The FREE promise is
//  the first, warmest thing in the body — read before the (quiet) price. Paying
//  unlocks nothing; it only hides the in-upload card. The single paste-a-key
//  field is the entire in-app "login" — the license key IS the identity.
//

import SwiftUI

struct SupporterSheet: View {
    @ObservedObject private var store = SupporterStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showKeyField = false
    @State private var keyText = ""
    @State private var unlockFailed = false
    @State private var heartScale: CGFloat = 0.7

    private let warm = LinearGradient(
        colors: [Color(red: 1.00, green: 0.42, blue: 0.55),
                 Color(red: 0.77, green: 0.36, blue: 0.96)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 16) {
                if store.isSupporter { memberBody } else { freeBody }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack {
            warm
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(.white.opacity(0.25)).frame(width: 78, height: 78)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        .scaleEffect(heartScale)
                }
                Text(LocalizedStringKey(store.isSupporter ? "support.settings.member_status" : "support.sheet.title"))
                    .font(.title2).fontWeight(.bold).foregroundStyle(.white)
                Text(LocalizedStringKey("support.sheet.tagline"))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 30).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { heartScale = 1.0 } }
    }

    // MARK: - Shared

    private var freePromiseCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(.green)
            Text(LocalizedStringKey("support.sheet.free_pill"))
                .font(.callout).fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Free

    private var freeBody: some View {
        VStack(spacing: 16) {
            freePromiseCard

            HStack(spacing: 12) {
                planCard(icon: "cup.and.saucer.fill",
                         title: "support.plan.tip_title",
                         sub: "support.plan.tip_sub",
                         price: nil,
                         cta: "support.plan.tip_cta",
                         highlighted: false)
                planCard(icon: "heart.fill",
                         title: "support.plan.member_title",
                         sub: "support.sheet.perk_hide",
                         price: "support.sheet.price",
                         cta: "support.sheet.cta_primary",
                         highlighted: true)
            }

            Button(LocalizedStringKey("support.sheet.cta_secondary")) { dismiss() }
                .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)

            keyArea
        }
    }

    /// One plan: the one-time tip or the monthly membership. Both open checkout +
    /// reveal the key field; the real billing (RevenueCat Web Billing or a license
    /// store) slots in behind store.openCheckout + unlock with no UI change.
    private func planCard(icon: String, title: String, sub: String,
                          price: String?, cta: String, highlighted: Bool) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 25))
                .foregroundStyle(highlighted ? AnyShapeStyle(warm) : AnyShapeStyle(Color.accentColor))
            Text(LocalizedStringKey(title)).font(.callout).fontWeight(.semibold)
            Text(LocalizedStringKey(sub)).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let price {
                Text(LocalizedStringKey(price)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                store.openCheckout()
                withAnimation { showKeyField = true }
            } label: {
                Text(LocalizedStringKey(cta))
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundStyle(highlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.accentColor))
                    .background(highlighted ? AnyShapeStyle(warm) : AnyShapeStyle(Color.accentColor.opacity(0.14)),
                                in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 158)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(highlighted ? AnyShapeStyle(warm) : AnyShapeStyle(Color.primary.opacity(0.08)),
                              lineWidth: highlighted ? 1.5 : 1)
        )
    }

    @ViewBuilder
    private var keyArea: some View {
        Divider().padding(.top, 2)
        if showKeyField {
            HStack(spacing: 8) {
                TextField(LocalizedStringKey("support.sheet.key_placeholder"), text: $keyText)
                    .textFieldStyle(.roundedBorder).onSubmit(tryUnlock)
                Button(LocalizedStringKey("support.sheet.unlock_button"), action: tryUnlock)
                    .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if unlockFailed {
                Text(LocalizedStringKey("support.sheet.unlock_failed"))
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack {
                Button(LocalizedStringKey("support.sheet.restore")) {
                    withAnimation { showKeyField = true }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(LocalizedStringKey("support.sheet.restore_button")) {
                    if !store.restore() { withAnimation { showKeyField = true } }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Member

    private var memberBody: some View {
        VStack(spacing: 16) {
            freePromiseCard
            Button(LocalizedStringKey("support.sheet.close")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func tryUnlock() {
        if store.unlock(key: keyText) {
            unlockFailed = false
            dismiss()
        } else {
            unlockFailed = true
        }
    }
}
