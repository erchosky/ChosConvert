import AppKit
import ChosConvertKit
import Foundation
import Observation
import QuickLookThumbnailing

/// A file the user dropped, with its inspection state.
@MainActor @Observable
public final class DroppedFile: Identifiable {
    public enum State: Equatable {
        case inspecting
        case ready(MediaInfo)
        case failed(ChosError)
    }

    public let id = UUID()
    public let url: URL
    public internal(set) var state: State = .inspecting
    public internal(set) var thumbnail: NSImage?

    init(url: URL) { self.url = url }

    public var info: MediaInfo? {
        if case .ready(let m) = state { return m }
        return nil
    }
}

/// The action the user picked, presented as a configuration sheet.
public struct ActionRequest: Identifiable, Hashable {
    public let id = UUID()
    public let action: SmartAction
    /// Preselected output format (from the command palette, e.g. "Convert to WebP").
    public var preferredFormat: FileFormat?

    public init(action: SmartAction, preferredFormat: FileFormat? = nil) {
        self.action = action
        self.preferredFormat = preferredFormat
    }
}

/// A finished conversion shown under "Recent results" in the menu bar. Session-only: persistent
/// history is a Phase 3 feature.
public struct RecentResult: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let finishedAt: Date
}

public enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case home, queue
    public var id: String { rawValue }
}

@MainActor @Observable
public final class AppModel {
    public let settings: AppSettings
    public let queue: JobQueue
    public private(set) var capabilities: Capabilities?
    public private(set) var files: [DroppedFile] = []
    public private(set) var actions: [SmartAction] = []
    public var section: AppSection = .home
    public var activeAction: ActionRequest?
    public var inspectedFileID: DroppedFile.ID?
    public var isInspectorShown = false
    public var lastAddError: ChosError?
    public var isPaletteShown = false
    public private(set) var recentResults: [RecentResult] = []
    /// An intent picked in the command palette before any file was loaded; it opens as soon as
    /// the files chosen next are inspected.
    public internal(set) var pendingPaletteIntent: PaletteIntent?

    /// Opens (or brings forward) the main window. Installed by the app shell, which owns the
    /// SwiftUI `openWindow` action; the Edge Dock and menu bar use it.
    @ObservationIgnored public var mainWindowOpener: (@MainActor () -> Void)?
    /// Extra observers of finished jobs (the Edge Dock uses it to refresh its result card).
    @ObservationIgnored var jobFinishedObservers: [@MainActor (JobItem) -> Void] = []
    @ObservationIgnored let notifier: CompletionNotifier
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    static let maxFilesPerDrop = 10_000
    static let maxRecentResults = 8

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        queue = JobQueue()
        notifier = CompletionNotifier(settings: settings)
        queue.maxConcurrentOverride = settings.maxConcurrentJobs > 0 ? settings.maxConcurrentJobs : nil
        queue.onFinished = { [weak self] item in self?.jobFinished(item) }
    }

    /// Loads capabilities and cleans stale temp space. Safe to call from several places (app
    /// launch, the main window, tests): the work runs once.
    public func bootstrap() async {
        if let bootstrapTask { return await bootstrapTask.value }
        let task = Task { await self.runBootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func runBootstrap() async {
        do { try CoreBridge.checkCompatibility() } catch {
            Log.app.fault("core ABI mismatch: \(error.details ?? "", privacy: .public)")
        }
        let report = TempSpace.shared.cleanupStale()
        if let report, report.removed > 0 {
            Log.app.info("removed \(report.removed) stale temp job dirs (\(report.freedBytes) bytes)")
        }
        await CapabilityService.shared.setCustomFFmpegPath(settings.customFFmpegPath)
        capabilities = await CapabilityService.shared.current()
        refreshActions()
    }

    public func reloadCapabilities() async {
        await CapabilityService.shared.setCustomFFmpegPath(settings.customFFmpegPath)
        capabilities = await CapabilityService.shared.refresh()
        refreshActions()
    }

    // MARK: Files

    public var readyFiles: [MediaInfo] { files.compactMap(\.info) }
    public var isInspecting: Bool { files.contains { $0.state == .inspecting } }
    public var inspectedFile: DroppedFile? { files.first { $0.id == inspectedFileID } ?? files.first }

    /// Adds files (folders are expanded, hidden files skipped) and inspects them.
    public func add(urls: [URL]) {
        let expanded = Self.expand(urls)
        let existing = Set(files.map { $0.url.standardizedFileURL })
        let new = expanded.filter { !existing.contains($0.standardizedFileURL) }.map(DroppedFile.init(url:))
        guard !new.isEmpty else { return }
        files.append(contentsOf: new)
        section = .home
        actions = []
        inspect(new)
    }

    public func remove(_ file: DroppedFile) {
        files.removeAll { $0.id == file.id }
        refreshActions()
    }

    public func clearFiles() {
        inspectionTask?.cancel()
        files.removeAll()
        actions = []
    }

    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            if isDir.boolValue && isPackage != true {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL, out.count < maxFilesPerDrop {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(f) }
                }
            } else {
                out.append(url)
            }
            if out.count >= maxFilesPerDrop { break }
        }
        return out
    }

    private func inspect(_ new: [DroppedFile]) {
        let previous = inspectionTask
        inspectionTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let caps: Capabilities
            if let c = self.capabilities {
                caps = c
            } else {
                caps = await CapabilityService.shared.current()
                self.capabilities = caps
            }
            // Bounded parallelism: at most 6 inspections (ffprobe processes) at once.
            await withTaskGroup(of: Void.self) { group in
                var iterator = new.makeIterator()
                func next() -> Bool {
                    guard let file = iterator.next() else { return false }
                    let url = file.url
                    group.addTask {
                        let state: DroppedFile.State
                        do throws(ChosError) {
                            state = .ready(try await Inspector.inspect(url, capabilities: caps))
                        } catch {
                            state = .failed(error)
                        }
                        await MainActor.run { file.state = state }
                    }
                    return true
                }
                for _ in 0..<6 where next() {}
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll(); break }
                    _ = next()
                }
            }
            self.refreshActions()
            // Thumbnails are cosmetic: generate them after actions are available.
            for file in new where file.thumbnail == nil {
                if Task.isCancelled { break }
                file.thumbnail = await Self.thumbnail(for: file.url)
            }
        }
    }

    nonisolated static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88),
                                                   scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    // MARK: Actions & jobs

    struct ActionsRequest: Encodable { var files: [MediaInfo]; var capabilities: Capabilities }

    public func refreshActions() {
        guard let caps = capabilities, !readyFiles.isEmpty else {
            actions = []
            return
        }
        actions = Self.actions(for: readyFiles, capabilities: caps)
        resolvePendingPaletteIntent()
    }

    /// Smart actions that work for every file, from the core planner (`actions.for_files`).
    nonisolated static func actions(for files: [MediaInfo], capabilities: Capabilities) -> [SmartAction] {
        guard !files.isEmpty else { return [] }
        do {
            return try CoreBridge.call("actions.for_files", ActionsRequest(files: files, capabilities: capabilities))
        } catch {
            Log.app.error("actions failed: \(error.code, privacy: .public)")
            return []
        }
    }

    /// Capabilities, loading them if the app hasn't bootstrapped yet (e.g. a drop on the Edge
    /// Dock right after launch).
    func currentCapabilities() async -> Capabilities {
        if let capabilities { return capabilities }
        let caps = await CapabilityService.shared.current()
        capabilities = caps
        return caps
    }

    public func plan(_ intent: Intent, options: AdvancedOptions, for file: MediaInfo) -> Result<ConversionPlan, ChosError> {
        guard let caps = capabilities else { return .failure(.internalError("capabilities not ready")) }
        do throws(ChosError) {
            return .success(try JobRunner.plan(JobSpec(input: file, intent: intent, options: options), capabilities: caps))
        } catch {
            return .failure(error)
        }
    }

    /// Applies global preferences to per-job options.
    func effectiveOptions(_ options: AdvancedOptions) -> AdvancedOptions {
        var o = options
        if o.encoder == nil, !settings.preferHardwareEncoding { o.encoder = .software }
        return o
    }

    public func start(_ intent: Intent, options: AdvancedOptions, files: [MediaInfo]) {
        enqueue(intent, options: options, files: files)
        activeAction = nil
        section = .queue
    }

    /// Queues jobs with the user's output policy and global preferences, without touching
    /// navigation (used directly by the Edge Dock, which must not pull the main window forward).
    @discardableResult
    func enqueue(_ intent: Intent, options: AdvancedOptions = AdvancedOptions(), files: [MediaInfo]) -> [JobItem] {
        let policy = settings.outputPolicy
        let specs = files.map { JobSpec(input: $0, intent: intent, options: effectiveOptions(options), policy: policy) }
        return queue.enqueue(specs)
    }

    private func jobFinished(_ item: JobItem) {
        if item.status == .completed, let url = item.outcome?.outputURL {
            recentResults.removeAll { $0.url == url }
            recentResults.insert(RecentResult(id: UUID(), url: url, finishedAt: item.completedAt ?? Date()), at: 0)
            if recentResults.count > Self.maxRecentResults { recentResults.removeLast(recentResults.count - Self.maxRecentResults) }
        }
        notifier.jobFinished(item)
        for observer in jobFinishedObservers { observer(item) }
    }

    /// Brings the main window forward, optionally on a section.
    public func showMainWindow(_ section: AppSection? = nil) {
        if let section { self.section = section }
        NSApp.activate()
        if let mainWindowOpener {
            mainWindowOpener()
        } else if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
