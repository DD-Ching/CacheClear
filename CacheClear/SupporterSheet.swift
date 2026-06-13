//
//  SupporterSheet.swift
//  CacheClear
//
//  The half-height "support the author" sheet. Designed so the FREE promise is
//  the warmest, top-most element — read before the (quiet) price. Paying unlocks
//  nothing; it only hides the in-upload card. The single paste-a-key field is the
//  entire in-app "login": the license key IS the identity — no account, no
//  password screen (any real account lives in the external browser checkout).
//

import SwiftUI

struct SupporterSheet: View {
    @ObservedObject private var store = SupporterStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showKeyField = false
    @State private var keyText = ""
    @State private var unlockFailed = false
    @State private var heartScale: CGFloat = 0.85

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.fill")
                .font(.system(size: 40))
                .foregroundColor(.pink)
                .scaleEffect(heartScale)
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { heartScale = 1.0 }
                }

            Text(LocalizedStringKey("support.sheet.title"))
                .font(.title2).fontWeight(.semibold)

            // The FREE promise — warmest, most prominent, ABOVE the price.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text(LocalizedStringKey("support.sheet.free_pill"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.green.opacity(0.12))
            .cornerRadius(8)

            if store.isSupporter {
                memberBody
            } else {
                freeBody
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Member

    private var memberBody: some View {
        VStack(spacing: 14) {
            Label(LocalizedStringKey("support.settings.member_status"), systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
            Button(LocalizedStringKey("support.sheet.close")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Free

    private var freeBody: some View {
        VStack(spacing: 12) {
            Text(LocalizedStringKey("support.sheet.body"))
                .font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey("support.sheet.price"))
                .font(.callout).foregroundColor(.secondary)

            Button {
                store.openCheckout()
                withAnimation { showKeyField = true }
            } label: {
                Text(LocalizedStringKey("support.sheet.cta_primary")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(LocalizedStringKey("support.sheet.cta_secondary")) { dismiss() }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)

            Divider().padding(.vertical, 2)

            if showKeyField {
                HStack(spacing: 8) {
                    TextField(LocalizedStringKey("support.sheet.key_placeholder"), text: $keyText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(tryUnlock)
                    Button(LocalizedStringKey("support.sheet.unlock_button"), action: tryUnlock)
                        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if unlockFailed {
                    Text(LocalizedStringKey("support.sheet.unlock_failed"))
                        .font(.caption).foregroundColor(.red)
                }
            } else {
                HStack {
                    Button(LocalizedStringKey("support.sheet.restore")) {
                        withAnimation { showKeyField = true }
                    }
                    .buttonStyle(.borderless).font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button(LocalizedStringKey("support.sheet.restore_button")) {
                        if !store.restore() { withAnimation { showKeyField = true } }
                    }
                    .buttonStyle(.borderless).font(.caption2).foregroundColor(.secondary)
                }
            }
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
