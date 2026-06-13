//
//  SupporterStore.swift
//  CacheClear
//
//  Owns whether the user is a supporter. Being a supporter unlocks NO features —
//  the app is fully functional for free — it only hides the small "support the
//  author" card shown during an upload. Mirrors OffloadSettings' UserDefaults
//  write-through pattern. All billing is isolated behind LicenseVerifier, so a
//  real external (non-App-Store) verifier drops in with zero UI change.
//

import Foundation
import AppKit
import Combine

@MainActor
final class SupporterStore: ObservableObject {
    static let shared = SupporterStore()

    enum SupporterState: Equatable {
        case free
        case member(unlockedAt: Date)
    }

    @Published private(set) var state: SupporterState = .free
    @Published var preUploadHeadsUpSeen: Bool {
        didSet { d.set(preUploadHeadsUpSeen, forKey: Keys.headsUp) }
    }

    private let d = UserDefaults.standard
    private let verifier: LicenseVerifier = StubVerifier()

    /// Where "Become a supporter" sends the user. Empty in the test build → the
    /// button simply reveals the paste-a-key field and the dev code unlocks.
    /// TODO: real Gumroad / Lemon Squeezy / Stripe payment link.
    private let checkoutURL: URL? = nil

    private enum Keys {
        static let unlockedAt = "supporter.unlockedAt"
        static let licenseKey = "supporter.licenseKey"   // NOTE: move to Keychain before real billing ships
        static let headsUp    = "supporter.preUploadHeadsUpSeen"
        static let heartPlays = "supporter.heartAnimationsPlayed"
    }

    var isSupporter: Bool {
        if case .member = state { return true } else { return false }
    }

    private init() {
        preUploadHeadsUpSeen = d.bool(forKey: Keys.headsUp)
        // Re-derive membership from the stored key so a future real verifier can
        // naturally drop a revoked/expired key back to .free on launch.
        if let key = d.string(forKey: Keys.licenseKey),
           verifier.verify(key),
           let date = d.object(forKey: Keys.unlockedAt) as? Date {
            state = .member(unlockedAt: date)
        }
    }

    /// Validate a pasted key; on success become a member. Returns whether it worked.
    @discardableResult
    func unlock(key: String) -> Bool {
        guard verifier.verify(key) else { return false }
        let now = Date()
        d.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.licenseKey)
        d.set(now, forKey: Keys.unlockedAt)
        state = .member(unlockedAt: now)
        return true
    }

    /// Re-verify the stored key (the "Restore" button).
    @discardableResult
    func restore() -> Bool {
        guard let key = d.string(forKey: Keys.licenseKey) else { return false }
        return unlock(key: key)
    }

    /// Undo membership (useful for testing the free experience again).
    func resignMembership() {
        d.removeObject(forKey: Keys.licenseKey)
        d.removeObject(forKey: Keys.unlockedAt)
        state = .free
    }

    /// Open the external checkout in the browser. No-ops cleanly until a real
    /// payment link is set, so the paste-a-key path still works in the test build.
    func openCheckout() {
        if let url = checkoutURL { NSWorkspace.shared.open(url) }
    }

    func dismissPreUploadHeadsUp() { preUploadHeadsUpSeen = true }

    /// The heart does its gentle one-shot scale-in only for the first few uploads,
    /// then rests forever — so it never becomes a recurring "banner-ad" twitch.
    func consumeHeartAnimation() -> Bool {
        let plays = d.integer(forKey: Keys.heartPlays)
        guard plays < 3 else { return false }
        d.set(plays + 1, forKey: Keys.heartPlays)
        return true
    }
}
