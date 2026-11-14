import Foundation
import Observation

public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
}

public enum OutputLocationMode: String, CaseIterable, Identifiable, Sendable {
    case sameFolder = "same_folder"
    case custom
    public var id: String { rawValue }
}

/// Which screen edge hosts the Edge Dock strip.
public enum EdgeDockSide: String, CaseIterable, Identifiable, Sendable {
    case left, right
    public var id: String { rawValue }
}

/// How wide the invisible drop strip is. Wider is easier to hit but covers more of the edge.
public enum EdgeDockSensitivity: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    public var id: String { rawValue }

    /// Strip width in points (independent of the display's scale factor).
    public var stripWidth: Double {
        switch self {
        case .low: 3
        case .medium: 6
        case .high: 12
        }
    }
}

/// Which displays show the Edge Dock.
public enum EdgeDockScreenChoice: Hashable, Sendable {
    case all
    /// The display that holds the menu bar.
    case main
    /// A specific display, identified by its stable display UUID.
    case display(String)

    public var rawValue: String {
        switch self {
        case .all: "all"
        case .main: "main"
        case .display(let id): "display:\(id)"
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "main": self = .main
        case let v where v.hasPrefix("display:") && v.count > 8: self = .display(String(v.dropFirst(8)))
        default: self = .all
        }
    }
}

/// User preferences, persisted in UserDefaults. Everything stays on this Mac.
@MainActor @Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var appearance: AppearancePreference { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    public var outputMode: OutputLocationMode { didSet { defaults.set(outputMode.rawValue, forKey: Keys.outputMode) } }
    public var customOutputFolder: String? { didSet { defaults.set(customOutputFolder, forKey: Keys.customOutputFolder) } }
    public var collision: CollisionPolicy { didSet { defaults.set(collision.rawValue, forKey: Keys.collision) } }
    /// 0 = automatic.
    public var maxConcurrentJobs: Int { didSet { defaults.set(maxConcurrentJobs, forKey: Keys.maxConcurrentJobs) } }
    public var preferHardwareEncoding: Bool { didSet { defaults.set(preferHardwareEncoding, forKey: Keys.preferHardware) } }
    public var notifyOnCompletion: Bool { didSet { defaults.set(notifyOnCompletion, forKey: Keys.notify) } }
    public var customFFmpegPath: String? { didSet { defaults.set(customFFmpegPath, forKey: Keys.ffmpegPath) } }
    public var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }
    public var showMenuBarExtra: Bool { didSet { defaults.set(showMenuBarExtra, forKey: Keys.menuBar) } }

    // Edge Dock
    public var edgeDockEnabled: Bool { didSet { defaults.set(edgeDockEnabled, forKey: Keys.dockEnabled) } }
    public var edgeDockSide: EdgeDockSide { didSet { defaults.set(edgeDockSide.rawValue, forKey: Keys.dockSide) } }
    public var edgeDockSensitivity: EdgeDockSensitivity {
        didSet { defaults.set(edgeDockSensitivity.rawValue, forKey: Keys.dockSensitivity) }
    }
    public var edgeDockScreens: EdgeDockScreenChoice { didSet { defaults.set(edgeDockScreens.rawValue, forKey: Keys.dockScreens) } }
    public var edgeDockHideInFullScreen: Bool { didSet { defaults.set(edgeDockHideInFullScreen, forKey: Keys.dockFullScreen) } }
    /// Removes Edge Dock animations even when the system "Reduce motion" setting is off.
    public var edgeDockReduceMotion: Bool { didSet { defaults.set(edgeDockReduceMotion, forKey: Keys.dockReduceMotion) } }

    enum Keys {
        static let appearance = "settings.appearance"
        static let outputMode = "settings.output.mode"
        static let customOutputFolder = "settings.output.customFolder"
        static let collision = "settings.output.collision"
        static let maxConcurrentJobs = "settings.processing.maxConcurrent"
        static let preferHardware = "settings.processing.preferHardware"
        static let notify = "settings.general.notify"
        static let ffmpegPath = "settings.advanced.ffmpegPath"
        static let onboarding = "settings.onboarding.done"
        static let menuBar = "settings.general.menuBar"
        static let dockEnabled = "settings.dock.enabled"
        static let dockSide = "settings.dock.side"
        static let dockSensitivity = "settings.dock.sensitivity"
        static let dockScreens = "settings.dock.screens"
        static let dockFullScreen = "settings.dock.hideInFullScreen"
        static let dockReduceMotion = "settings.dock.reduceMotion"
        static let all = [appearance, outputMode, customOutputFolder, collision, maxConcurrentJobs, preferHardware, notify,
                          ffmpegPath, onboarding, menuBar, dockEnabled, dockSide, dockSensitivity, dockScreens,
                          dockFullScreen, dockReduceMotion]
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearancePreference(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        outputMode = OutputLocationMode(rawValue: defaults.string(forKey: Keys.outputMode) ?? "") ?? .sameFolder
        customOutputFolder = defaults.string(forKey: Keys.customOutputFolder)
        collision = CollisionPolicy(rawValue: defaults.string(forKey: Keys.collision) ?? "") ?? .rename
        maxConcurrentJobs = defaults.object(forKey: Keys.maxConcurrentJobs) as? Int ?? 0
        preferHardwareEncoding = defaults.object(forKey: Keys.preferHardware) as? Bool ?? true
        notifyOnCompletion = defaults.object(forKey: Keys.notify) as? Bool ?? true
        customFFmpegPath = defaults.string(forKey: Keys.ffmpegPath)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        showMenuBarExtra = defaults.object(forKey: Keys.menuBar) as? Bool ?? true
        edgeDockEnabled = defaults.object(forKey: Keys.dockEnabled) as? Bool ?? true
        edgeDockSide = EdgeDockSide(rawValue: defaults.string(forKey: Keys.dockSide) ?? "") ?? .right
        edgeDockSensitivity = EdgeDockSensitivity(rawValue: defaults.string(forKey: Keys.dockSensitivity) ?? "") ?? .medium
        edgeDockScreens = EdgeDockScreenChoice(rawValue: defaults.string(forKey: Keys.dockScreens) ?? "all")
        edgeDockHideInFullScreen = defaults.object(forKey: Keys.dockFullScreen) as? Bool ?? true
        edgeDockReduceMotion = defaults.bool(forKey: Keys.dockReduceMotion)
    }

    public var outputPolicy: OutputPolicy {
        if outputMode == .custom, let folder = customOutputFolder, !folder.isEmpty {
            return OutputPolicy(location: .custom(directory: folder), collision: collision)
        }
        return OutputPolicy(location: .sameFolder, collision: collision)
    }

    public func resetAll() {
        for key in Keys.all { defaults.removeObject(forKey: key) }
        appearance = .system; outputMode = .sameFolder; customOutputFolder = nil; collision = .rename
        maxConcurrentJobs = 0; preferHardwareEncoding = true; notifyOnCompletion = true; customFFmpegPath = nil
        hasCompletedOnboarding = false
        showMenuBarExtra = true
        edgeDockEnabled = true; edgeDockSide = .right; edgeDockSensitivity = .medium; edgeDockScreens = .all
        edgeDockHideInFullScreen = true; edgeDockReduceMotion = false
    }
}
