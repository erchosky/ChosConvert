import AppKit
import ChosConvertKit
import Foundation
import Observation

/// State of the Edge Dock, independent of windows: the controller mirrors it into panels and the
/// SwiftUI views render it. Driven by the drag watcher and the panels' drag-destination callbacks.
@MainActor @Observable
final class EdgeDockModel {
    enum Content: Equatable {
        /// Hovering: the dragged files are being identified.
        case reading
        /// Hovering: actions are ready to receive the drop.
        case ready
        /// Hovering: nothing to offer (see `notice`); "Open in ChosConvert" is still a target.
        case unavailable
        /// Files were dropped on the panel itself; actions are clickable buttons now.
        case held
        /// Jobs started from the dock: progress, then results with drag-out.
        case working
    }

    struct Panel: Equatable {
        var screenID: String
        var anchorY: CGFloat
        var content: Content
    }

    /// Files beyond this are not inspected while hovering (the drop opens them in the app).
    static let hoverFileLimit = 24
    /// How long a finished result card stays when the pointer is not over it.
    static let resultLinger: Duration = .seconds(8)
    /// Delay before collapsing after the drag leaves the panel, so brief exits don't flicker.
    static let exitGrace: Duration = .milliseconds(250)

    let app: AppModel
    /// A drag carrying files is in progress somewhere on the system: strips are visible.
    private(set) var isDragActive = false
    private(set) var panel: Panel?
    private(set) var urls: [URL] = []
    private(set) var files: [MediaInfo] = []
    private(set) var rows: [DockRow] = []
    /// Localized explanation for `.unavailable` or skipped files.
    private(set) var notice: String?
    private(set) var jobs: [JobItem] = []
    var hoveredTargetID: String?
    /// Measured height of the card, reported by the view; the controller sizes the window to it.
    var cardHeight: CGFloat = 220
    /// Target frames in the panel's SwiftUI coordinate space, for hit-testing the drag.
    @ObservationIgnored var targetFrames: [String: CGRect] = [:]
    /// The pointer is over the result card (it stays while hovered).
    var isPointerInside = false { didSet { if !isPointerInside { scheduleLingerDismiss() } } }

    @ObservationIgnored private var inspection: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var cacheKey: [URL] = []
    /// Inspection results of the current drag session, so re-entering the strip is instant.
    @ObservationIgnored private var sessionCache: [URL: Result<MediaInfo, ChosError>] = [:]

    init(app: AppModel) {
        self.app = app
        app.jobFinishedObservers.append { [weak self] item in self?.jobFinished(item) }
    }

    var isHovering: Bool {
        guard let c = panel?.content else { return false }
        return [.reading, .ready, .unavailable].contains(c)
    }

    var targets: [DockTarget] { rows.flatMap(\.targets) + [DockTargets.openInApp] }

    /// The target under `point` (SwiftUI coordinates of the expanded panel), if any.
    func target(at point: CGPoint) -> DockTarget? {
        guard let content = panel?.content, content == .ready || content == .unavailable || content == .held else { return nil }
        let candidates = content == .unavailable ? [DockTargets.openInApp] : targets
        return candidates.first { targetFrames[$0.id]?.contains(point) == true }
    }

    // MARK: Drag session (from DragSessionWatcher)

    func dragBegan() {
        isDragActive = true
        sessionCache = [:]
    }

    func dragEnded() {
        isDragActive = false
        // The drop (performDragOperation) and the button release race; give the drop a moment.
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.isHovering else { return }
            self.close()
        }
    }

    // MARK: Hover (from the panel's NSDraggingDestination)

    func hoverEntered(screenID: String, urls: [URL], anchorY: CGFloat) {
        collapseTask?.cancel()
        if let panel, panel.content == .working || panel.content == .held {
            // A new drag over a busy card on this screen just targets it; other screens expand.
            if panel.screenID == screenID { return }
        }
        let fileURLs = urls.filter(\.isFileURL)
        panel = Panel(screenID: screenID, anchorY: anchorY, content: .reading)
        hoveredTargetID = nil
        if fileURLs.map(\.standardizedFileURL) == cacheKey, !rows.isEmpty || notice != nil {
            panel?.content = rows.isEmpty ? .unavailable : .ready
            return
        }
        self.urls = fileURLs
        cacheKey = fileURLs.map(\.standardizedFileURL)
        startInspection(fileURLs, hovering: true)
    }

    func hoverExited() {
        guard isHovering else { return }
        hoveredTargetID = nil
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.exitGrace)
            guard let self, !Task.isCancelled, self.isHovering else { return }
            self.close()
        }
    }

    /// The drop. Returns whether it was accepted. `targetID` is nil when the files were released
    /// over the panel but not over a target: they are then held for a click.
    @discardableResult
    func drop(urls dropped: [URL], on targetID: String?) -> Bool {
        collapseTask?.cancel()
        let fileURLs = dropped.filter(\.isFileURL)
        guard !fileURLs.isEmpty, panel != nil else { return false }
        if fileURLs.map(\.standardizedFileURL) != cacheKey {
            urls = fileURLs
            cacheKey = fileURLs.map(\.standardizedFileURL)
            files = []; rows = []; notice = nil
        }
        if targetID == DockTargets.openInAppID {
            openInApp()
            return true
        }
        if let targetID, panel?.content == .ready, let target = targets.first(where: { $0.id == targetID }) {
            run(target)
            return true
        }
        // Released over the panel (or before the actions were ready): keep the files. Now that
        // the drop granted access (sandbox), unreadable files are inspected again.
        sessionCache = sessionCache.filter { if case .success = $0.value { true } else { false } }
        jobs = []
        panel?.content = .held
        startInspection(fileURLs, hovering: false)
        return true
    }

    // MARK: Actions

    func run(_ target: DockTarget) {
        switch target.kind {
        case .openInApp:
            openInApp()
        case .run(let intent):
            guard !files.isEmpty else { return }
            let items = app.enqueue(intent, files: files)
            jobs = items
            hoveredTargetID = nil
            lingerTask?.cancel()
            panel?.content = .working
        }
    }

    func openInApp() {
        app.add(urls: urls)
        app.showMainWindow(.home)
        close()
    }

    func showQueue() {
        app.showMainWindow(.queue)
        close()
    }

    func close() {
        inspection?.cancel()
        collapseTask?.cancel()
        lingerTask?.cancel()
        panel = nil
        hoveredTargetID = nil
        isPointerInside = false
        jobs = []
    }

    var allJobsFinished: Bool { !jobs.isEmpty && jobs.allSatisfy { $0.status.isTerminal } }

    private func jobFinished(_ item: JobItem) {
        guard panel?.content == .working, jobs.contains(where: { $0.id == item.id }), allJobsFinished else { return }
        scheduleLingerDismiss()
    }

    private func scheduleLingerDismiss() {
        guard panel?.content == .working, allJobsFinished, !isPointerInside else { return }
        lingerTask?.cancel()
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resultLinger)
            guard let self, !Task.isCancelled, !self.isPointerInside, self.panel?.content == .working else { return }
            self.close()
        }
    }

    // MARK: Inspection (core `detect.path` via Inspector, then `actions.for_files`)

    private func startInspection(_ urls: [URL], hovering: Bool) {
        inspection?.cancel()
        let expanded = AppModel.expand(urls)
        if hovering && expanded.count > Self.hoverFileLimit {
            files = []; rows = []
            notice = L.f("dock.notice.many", expanded.count)
            panel?.content = .unavailable
            return
        }
        files = []; rows = []; notice = nil
        let cache = sessionCache
        inspection = Task { [weak self] in
            guard let self else { return }
            let caps = await self.app.currentCapabilities()
            var results: [URL: Result<MediaInfo, ChosError>] = [:]
            await withTaskGroup(of: (URL, Result<MediaInfo, ChosError>).self) { group in
                for url in expanded {
                    if let cached = cache[url] { results[url] = cached; continue }
                    group.addTask {
                        do throws(ChosError) {
                            return (url, .success(try await Inspector.inspect(url, capabilities: caps)))
                        } catch {
                            return (url, .failure(error))
                        }
                    }
                }
                for await (url, result) in group { results[url] = result }
            }
            guard !Task.isCancelled else { return }
            for (url, r) in results { self.sessionCache[url] = r }
            self.apply(expanded.compactMap { results[$0] }, capabilities: caps, hovering: hovering)
        }
    }

    private func apply(_ results: [Result<MediaInfo, ChosError>], capabilities: Capabilities, hovering: Bool) {
        let ready = results.compactMap { try? $0.get() }
        let errors = results.compactMap { if case .failure(let e) = $0 { e } else { nil } }
        files = ready
        rows = DockTargets.rows(for: AppModel.actions(for: ready, capabilities: capabilities), files: ready)
        if ready.isEmpty {
            if hovering, errors.contains(where: \.isAccessDenied) {
                notice = L.s("dock.notice.drop_to_read")
            } else if let first = errors.first, errors.count == 1 {
                notice = L.error(first)
            } else {
                notice = L.s("dock.notice.unsupported")
            }
        } else if rows.isEmpty {
            notice = L.s("dock.notice.no_common")
        } else if !errors.isEmpty {
            notice = L.f("dock.notice.skipped", errors.count)
        } else {
            notice = nil
        }
        guard var p = panel else { return }
        if p.content == .reading { p.content = rows.isEmpty ? .unavailable : .ready }
        panel = p
    }
}

extension ChosError {
    /// The file exists but this process may not read it yet (sandbox before the drop).
    var isAccessDenied: Bool {
        // The core maps EACCES/EPERM to `output_not_writable` with the OS message in `details`.
        code == "output_not_writable"
            || (details?.localizedCaseInsensitiveContains("operation not permitted") ?? false)
            || (details?.localizedCaseInsensitiveContains("permission denied") ?? false)
    }
}
