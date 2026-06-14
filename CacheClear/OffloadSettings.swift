//
//  OffloadSettings.swift
//  CacheClear
//
//  Persisted user preferences for the GitHub Offload & Reclaim feature.
//

import Foundation
import Combine

final class OffloadSettings: ObservableObject {
    static let shared = OffloadSettings()

    private let d = UserDefaults.standard
    private enum Key {
        static let root = "offload.projectsRootPath"
        static let inactiveDays = "offload.inactiveDays"
        static let autoCreatePrivate = "offload.autoCreatePrivate"
        static let permanentDelete = "offload.permanentDelete"
        static let skipConfirm = "offload.skipConfirm"
    }

    @Published var projectsRootPath: String? {
        didSet { d.set(projectsRootPath, forKey: Key.root) }
    }
    @Published var inactiveDays: Int {
        didSet { d.set(inactiveDays, forKey: Key.inactiveDays) }
    }
    @Published var autoCreatePrivate: Bool {
        didSet { d.set(autoCreatePrivate, forKey: Key.autoCreatePrivate) }
    }
    /// false → move to Trash (default, recoverable); true → permanent rm.
    @Published var permanentDelete: Bool {
        didSet { d.set(permanentDelete, forKey: Key.permanentDelete) }
    }
    /// true → skip the per-offload confirmation dialog ("Don't ask me again").
    /// The verify-before-delete safety gate still runs regardless.
    @Published var skipOffloadConfirm: Bool {
        didSet { d.set(skipOffloadConfirm, forKey: Key.skipConfirm) }
    }

    private init() {
        projectsRootPath = d.string(forKey: Key.root)
        inactiveDays = d.object(forKey: Key.inactiveDays) as? Int ?? 14
        autoCreatePrivate = d.object(forKey: Key.autoCreatePrivate) as? Bool ?? true
        permanentDelete = d.bool(forKey: Key.permanentDelete) // defaults false
        skipOffloadConfirm = d.bool(forKey: Key.skipConfirm)  // defaults false
    }

    var deletionModeString: String { permanentDelete ? "permanent" : "trash" }
}
