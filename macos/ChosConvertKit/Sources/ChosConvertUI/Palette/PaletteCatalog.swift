import ChosConvertKit
import Foundation

/// An intent chosen from the command palette.
public enum PaletteIntent: Hashable, Sendable {
    case action(ActionID, format: FileFormat?)
    /// "Compress video": make smaller, offered only for videos.
    case compressVideo
    /// "Privacy Safe": remove all personal metadata (location, camera, dates, names).
    case privacySafe

    var actionID: ActionID {
        switch self {
        case .action(let id, _): id
        case .compressVideo: .makeSmaller
        case .privacySafe: .removeMetadata
        }
    }

    var format: FileFormat? {
        if case .action(_, let f) = self { return f }
        return nil
    }

    /// Stable identifier, e.g. "convert.webp" or "privacy_safe".
    var key: String {
        switch self {
        case .action(let id, let f): f.map { "\(id.rawValue).\($0.rawValue)" } ?? id.rawValue
        case .compressVideo: "compress_video"
        case .privacySafe: "privacy_safe"
        }
    }
}

/// One palette entry.
struct PaletteCommand: Identifiable, Hashable {
    enum Kind: Hashable {
        case intent(PaletteIntent)
        case navigate(AppSection)
        case addFiles
        case settings
        case toggleEdgeDock
        case clearFinished
        case cancelAll
    }

    var id: String
    var kind: Kind
    var title: String
    var symbol: String
    /// Extra search terms (English and Spanish synonyms, format names), never shown.
    var keywords: [String] = []
    /// Why the command can't run right now (shown instead of hiding it).
    var disabledReason: String?

    var isEnabled: Bool { disabledReason == nil }
    var isIntent: Bool { if case .intent = kind { true } else { false } }
}

/// The palette's command list for the current app state.
@MainActor
enum PaletteCatalog {
    /// Conversion targets suggested when no file is loaded yet.
    static let suggestedFormats: [FileFormat] = [.webp, .jpeg, .png, .heic, .mp4, .mov, .gif, .mp3, .m4a, .wav]

    static func commands(for model: AppModel) -> [PaletteCommand] {
        var out = intentCommands(actions: model.actions, families: Set(model.readyFiles.map(\.family)),
                                 hasFiles: !model.readyFiles.isEmpty)
        out.append(PaletteCommand(id: "nav.queue", kind: .navigate(.queue), title: L.s("palette.open_queue"),
                                  symbol: "list.bullet.rectangle", keywords: ["queue", "jobs", "progress", "cola", "trabajos"]))
        out.append(PaletteCommand(id: "nav.home", kind: .navigate(.home), title: L.s("palette.open_home"),
                                  symbol: "square.and.arrow.down", keywords: ["home", "files", "inicio", "archivos"]))
        out.append(PaletteCommand(id: "add", kind: .addFiles, title: L.s("menu.add"), symbol: "plus",
                                  keywords: ["open", "add", "import", "abrir", "añadir"]))
        out.append(PaletteCommand(id: "settings", kind: .settings, title: L.s("palette.settings"), symbol: "gearshape",
                                  keywords: ["preferences", "settings", "ajustes", "preferencias"]))
        out.append(PaletteCommand(id: "dock", kind: .toggleEdgeDock,
                                  title: L.s(model.settings.edgeDockEnabled ? "palette.dock.off" : "palette.dock.on"),
                                  symbol: "sidebar.right", keywords: ["edge", "dock", "borde", "panel"]))
        let finished = model.queue.hasFinished
        out.append(PaletteCommand(id: "clear", kind: .clearFinished, title: L.s("queue.clear"), symbol: "checkmark.circle.badge.xmark",
                                  keywords: ["clear", "clean", "limpiar"],
                                  disabledReason: finished ? nil : L.s("palette.reason.no_finished")))
        let active = model.queue.activeCount + model.queue.waitingCount > 0
        out.append(PaletteCommand(id: "cancel", kind: .cancelAll, title: L.s("queue.cancel.all"), symbol: "stop.circle",
                                  keywords: ["stop", "cancel", "detener", "cancelar"],
                                  disabledReason: active ? nil : L.s("palette.reason.no_active")))
        return out
    }

    /// Intent commands. With files loaded, they come from the core's smart actions (so only
    /// real options are enabled); without files, a curated list that asks for files first.
    static func intentCommands(actions: [SmartAction], families: Set<FileFamily>, hasFiles: Bool) -> [PaletteCommand] {
        let available = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let unavailable = L.s("palette.reason.unavailable")
        func reason(_ id: ActionID, format: FileFormat? = nil) -> String? {
            guard hasFiles else { return nil }
            guard let action = available[id] else { return unavailable }
            if let format, !(action.formats ?? []).contains(format) { return unavailable }
            return nil
        }
        func cmd(_ intent: PaletteIntent, _ title: String, _ symbol: String, _ keywords: [String], reason r: String?) -> PaletteCommand {
            PaletteCommand(id: "intent.\(intent.key)", kind: .intent(intent), title: title, symbol: symbol,
                           keywords: keywords, disabledReason: r)
        }

        var out: [PaletteCommand] = []
        // Convert to …: the formats the planner offers for the loaded files, or suggestions.
        let formats: [FileFormat] = hasFiles ? (available[.convert]?.formats ?? []) : suggestedFormats
        for f in formats {
            out.append(cmd(.action(.convert, format: f), L.f("palette.convert_to", f.displayName), ActionID.convert.symbol,
                           ["convert", "convertir", "export", "exportar", f.rawValue, f.displayName], reason: reason(.convert, format: f)))
        }
        out.append(cmd(.action(.makeSmaller, format: nil), L.s(ActionID.makeSmaller.titleKey), ActionID.makeSmaller.symbol,
                       ["compress", "reduce", "shrink", "smaller", "comprimir", "reducir", "achicar"], reason: reason(.makeSmaller)))
        let videoOnly = hasFiles && families != [.video] ? L.s("palette.reason.video_only") : nil
        out.append(cmd(.compressVideo, L.s("palette.compress_video"), "film",
                       ["compress", "video", "movie", "comprimir", "vídeo", "película", "smaller"],
                       reason: videoOnly ?? reason(.makeSmaller)))
        out.append(cmd(.privacySafe, L.s("palette.privacy_safe"), "lock.shield",
                       ["privacy", "metadata", "exif", "location", "gps", "privacidad", "metadatos", "ubicación"],
                       reason: reason(.removeMetadata)))
        let others: [(ActionID, [String])] = [
            (.removeLocation, ["location", "gps", "ubicación", "privacy", "privacidad"]),
            (.targetSize, ["target", "size", "mb", "email", "discord", "tamaño", "límite"]),
            (.extractAudio, ["audio", "sound", "mp3", "sonido", "extraer"]),
            (.webOptimize, ["web", "website", "optimize", "optimizar", "webp"]),
            (.resize, ["resize", "scale", "dimensions", "redimensionar", "escalar"]),
            (.createGif, ["gif", "animation", "animación"]),
            (.removeMetadata, ["metadata", "exif", "strip", "metadatos"]),
        ]
        for (id, keywords) in others {
            // Without files, keep the list short: actions that depend on content appear once loaded.
            if !hasFiles, id == .removeLocation || id == .createGif { continue }
            out.append(cmd(.action(id, format: nil), L.s(id.titleKey), id.symbol, keywords, reason: reason(id)))
        }
        return out
    }
}

/// Fuzzy matching for the palette: case- and accent-insensitive, matches words by prefix and
/// falls back to in-order characters ("cwebp" → "Convert to WebP").
enum PaletteSearch {
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Higher is better; nil when the command doesn't match.
    static func score(_ query: String, _ command: PaletteCommand) -> Int? {
        let q = normalize(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let title = normalize(command.title)
        let keywords = command.keywords.map(normalize)
        let tokens = q.split(separator: " ").map(String.init)
        var total = 0
        for token in tokens {
            let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if title.hasPrefix(token) { total += 100 }
            else if words.contains(where: { $0.hasPrefix(token) }) { total += 70 }
            else if keywords.contains(where: { $0.hasPrefix(token) }) { total += 50 }
            else if title.contains(token) || keywords.contains(where: { $0.contains(token) }) { total += 30 }
            else if isSubsequence(token, of: title) { total += 10 }
            else { return nil }
        }
        return total
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        return needle.allSatisfy { c in
            while let h = it.next() { if h == c { return true } }
            return false
        }
    }

    /// Matching commands, best first; enabled before disabled; stable otherwise.
    static func filter(_ query: String, _ commands: [PaletteCommand]) -> [PaletteCommand] {
        commands.enumerated()
            .compactMap { pair in score(query, pair.element).map { (pair.offset, pair.element, $0) } }
            .sorted { a, b in
                if a.1.isEnabled != b.1.isEnabled { return a.1.isEnabled }
                if a.2 != b.2 { return a.2 > b.2 }
                return a.0 < b.0
            }
            .map(\.1)
    }
}
