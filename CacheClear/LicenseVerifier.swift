//
//  LicenseVerifier.swift
//  CacheClear
//
//  The single seam where real billing slots in later. Today it is a stub that
//  accepts any non-empty key (so the author + a tester can unlock without a live
//  store). Tomorrow it becomes a Gumroad / Lemon Squeezy / Stripe key validator
//  (a URLSession POST to the vendor's validate endpoint, or an offline Ed25519
//  signature check against a bundled public key — no server needed).
//
//  Deliberately NOT StoreKit: the App Sandbox is intentionally disabled so git/gh
//  auth works, which means the Mac App Store is not a distribution target. All
//  payment therefore stays external (browser checkout + a pasted key). Swapping
//  the verifier below changes ZERO UI.
//

import Foundation

protocol LicenseVerifier {
    func verify(_ key: String) -> Bool
}

/// Test-build verifier: any non-empty key unlocks. The dev code is documented for
/// the author + classmate; it is just a memorable non-empty key (no view ever
/// references it — the rule is simply "non-empty").
struct StubVerifier: LicenseVerifier {
    /// A memorable always-valid code for the author + classmate during testing.
    static let devCode = "CACHECLEAR-SUPPORTER"

    func verify(_ key: String) -> Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
