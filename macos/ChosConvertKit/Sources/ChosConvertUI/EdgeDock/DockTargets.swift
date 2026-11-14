import ChosConvertKit
import Foundation

/// One drop target in the expanded Edge Dock. Dropping files on it starts the job right away with
/// a sensible default intent (the main window's configurator is for fine-tuning).
struct DockTarget: Identifiable, Hashable {
    enum Kind: Hashable {
        case run(Intent)
        /// Adds the files to the main window to choose and configure there.
        case openInApp
    }

    var id: String
    var kind: Kind
    /// Short label for chips ("WebP", "10 MB"); rows use their action title.
    var label: String?
}

/// A row in the expanded panel: one action, with one target or several variant chips.
struct DockRow: Identifiable, Hashable {
    var id: String { action.rawValue }
    var action: ActionID
    var targets: [DockTarget]
    var isPrimary: Bool

    var hasVariants: Bool { targets.count > 1 }
}

/// Builds Edge Dock rows from the core's smart actions. Pure, so default intents are unit-tested.
enum DockTargets {
    static let openInAppID = "open_in_app"
    /// Variant chips that fit the panel width.
    static let maxChips = 4
    static let targetSizes: [UInt64] = [10_000_000, 25_000_000]

    /// Output formats people reach for first, per family; only the ones the core offers are used.
    static func preferredFormats(for family: FileFamily) -> [FileFormat] {
        switch family {
        case .image: [.webp, .jpeg, .png, .heic, .avif]
        case .video: [.mp4, .mov, .webm, .gif]
        case .audio: [.mp3, .m4a, .wav, .flac]
        default: []
        }
    }

    static func rows(for actions: [SmartAction], files: [MediaInfo]) -> [DockRow] {
        let family = files.first?.family ?? .unknown
        var rows: [DockRow] = []
        for action in actions {
            let targets = targets(for: action, family: family, files: files)
            guard !targets.isEmpty else { continue }
            rows.append(DockRow(action: action.id, targets: targets, isPrimary: action.primary))
        }
        // Primary actions first, keeping the core's order inside each group.
        return rows.filter(\.isPrimary) + rows.filter { !$0.isPrimary }
    }

    static func targets(for action: SmartAction, family: FileFamily, files: [MediaInfo]) -> [DockTarget] {
        func single(_ intent: Intent) -> [DockTarget] {
            [DockTarget(id: action.id.rawValue, kind: .run(intent), label: nil)]
        }
        switch action.id {
        case .makeSmaller:
            return single(.makeSmaller(.balanced))
        case .targetSize:
            return targetSizes.map { bytes in
                DockTarget(id: "target_size.\(bytes)", kind: .run(.targetSize(bytes: bytes)),
                           label: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
        case .convert:
            let offered = action.formats ?? []
            var formats = preferredFormats(for: family).filter(offered.contains)
            for f in offered where !formats.contains(f) { formats.append(f) }
            return formats.prefix(maxChips).map { f in
                DockTarget(id: "convert.\(f.rawValue)", kind: .run(.convert(f)), label: f.displayName)
            }
        case .extractAudio:
            // Keeps the original audio stream when possible (no re-encode).
            return single(.extractAudio(nil))
        case .createGif:
            let shortest = files.compactMap(\.durationS).min() ?? 5
            return single(.createGif(startS: 0, durationS: max(0.5, min(5, shortest)), width: 480, fps: 12))
        case .resize:
            return single(.resize(maxDimension: family == .video ? 1080 : 1920))
        case .webOptimize:
            return single(.webOptimize)
        case .removeMetadata:
            return single(.removeMetadata(.all))
        case .removeLocation:
            return single(.removeMetadata(.location))
        }
    }

    static let openInApp = DockTarget(id: openInAppID, kind: .openInApp, label: nil)
}
