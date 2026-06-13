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

    private init() {
        projectsRootPath = d.string(forKey: Key.root)
        inactiveDays = d.object(forKey: Key.inactiveDays) as? Int ?? 14
        autoCreatePrivate = d.object(forKey: Key.autoCreatePrivate) as? Bool ?? true
        permanentDelete = d.bool(forKey: Key.permanentDelete) // defaults false
    }

    var deletionModeString: String { permanentDelete ? "permanent" : "trash" }
}
