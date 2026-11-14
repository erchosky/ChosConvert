import AppKit
import ChosConvertKit
import Observation
import SwiftUI

/// Owns the Edge Dock windows: one panel per eligible display, created from the current screen
/// arrangement and rebuilt when displays or settings change. Mirrors `EdgeDockModel` into window
/// frames and visibility. Runs from app launch, independent of the main window.
@MainActor
public final class EdgeDockController {
    let model: EdgeDockModel
    let settings: AppSettings
    private let watcher: DragSessionWatcher
    private var panels: [String: EdgeDockPanel] = [:]
    private var screens: [DockScreen] = []
    /// Screens showing a full-screen app during the current drag (strip suppressed there).
    private var fullScreenScreens: Set<String> = []
    private var activity: (any NSObjectProtocol)?
    private var screenObserver: (any NSObjectProtocol)?
    private var started = false

    public convenience init(app: AppModel) {
        self.init(model: EdgeDockModel(app: app), settings: app.settings, watcher: DragSessionWatcher())
    }

    init(model: EdgeDockModel, settings: AppSettings, watcher: DragSessionWatcher) {
        self.model = model
        self.settings = settings
        self.watcher = watcher
        watcher.onEvent = { [weak self] event in self?.handle(event) }
    }

    public func start() {
        guard !started else { return }
        started = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
        observeSettings()
        observeModel()
        applyEnabled()
    }

    // MARK: Settings

    private func observeSettings() {
        withObservationTracking {
            _ = settings.edgeDockEnabled
            _ = settings.edgeDockSide
            _ = settings.edgeDockSensitivity
            _ = settings.edgeDockScreens
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyEnabled()
                self?.observeSettings()
            }
        }
    }

    private func applyEnabled() {
        if settings.edgeDockEnabled {
            if activity == nil {
                // Keeps the 120 ms drag sampling on time while the app is in the background
                // (App Nap would otherwise stretch timers to seconds). Idle system sleep is allowed.
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                                 reason: "Edge Dock watches for file drags")
            }
            watcher.start()
            rebuildPanels()
        } else {
            watcher.stop()
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            model.close()
            for panel in panels.values { panel.orderOut(nil) }
            panels.removeAll()
        }
    }

    // MARK: Panels

    func rebuildPanels() {
        screens = DockScreen.current()
        guard settings.edgeDockEnabled else { return }
        let eligible = Set(EdgeDockGeometry.screens(for: settings.edgeDockScreens, in: screens).map(\.id))
        for (id, panel) in panels where !eligible.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for id in eligible where panels[id] == nil {
            panels[id] = makePanel(screenID: id)
        }
        if let p = model.panel, !p.screenID.isEmpty, !eligible.contains(p.screenID) { model.close() }
        updateWindows()
    }

    private func makePanel(screenID: String) -> EdgeDockPanel {
        let panel = EdgeDockPanel(screenID: screenID)
        let root = EdgeDockRootView(model: model, settings: settings, screenID: screenID)
        let hosting = EdgeDockHostingView(rootView: root)
        let drop = EdgeDockDropView(screenID: screenID, hostingView: hosting)
        drop.controller = self
        panel.contentView = drop
        return panel
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.isDragActive
            _ = model.panel
            _ = model.cardHeight
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateWindows()
                self?.observeModel()
            }
        }
    }

    /// Positions and shows/hides every panel for the current model state.
    func updateWindows() {
        let side = settings.edgeDockSide
        let width = CGFloat(settings.edgeDockSensitivity.stripWidth)
        for (id, panel) in panels {
            guard let screen = screens.first(where: { $0.id == id }) else {
                panel.orderOut(nil)
                continue
            }
            if let p = model.panel, p.screenID == id {
                let frame = EdgeDockGeometry.panelFrame(for: screen, side: side, anchorY: p.anchorY, height: model.cardHeight)
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                panel.hasShadow = false // the card draws its own shadow inside the transparent margin
                panel.orderFrontRegardless()
            } else if model.isDragActive, !fullScreenScreens.contains(id),
                      let frame = EdgeDockGeometry.stripFrame(for: screen, side: side, width: width, among: screens) {
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                panel.orderFrontRegardless()
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    // MARK: Drag session

    private func handle(_ event: DragSessionWatcher.Event) {
        switch event {
        case .began:
            screens = DockScreen.current()
            fullScreenScreens = settings.edgeDockHideInFullScreen ? detectFullScreen() : []
            model.dragBegan()
        case .ended:
            model.dragEnded()
        }
    }

    private func detectFullScreen() -> Set<String> {
        let windows = WindowSnapshot.onScreen()
        let primaryHeight = screens.first(where: \.isMain)?.frame.height ?? 0
        let pid = ProcessInfo.processInfo.processIdentifier
        return Set(screens.filter {
            EdgeDockGeometry.isFullScreen($0, windows: windows, primaryHeight: primaryHeight, ownPID: pid)
        }.map(\.id))
    }

    // MARK: Drag destination callbacks (EdgeDockDropView)

    func accepts(fromOwnApp: Bool) -> Bool {
        // Results dragged out of the dock's own card must not drop back onto it.
        !(fromOwnApp && model.panel?.content == .working)
    }

    func dragEntered(screenID: String, urls: [URL], screenPoint: CGPoint) {
        model.hoverEntered(screenID: screenID, urls: urls, anchorY: screenPoint.y)
    }

    func dragMoved(screenID: String, point: CGPoint) -> NSDragOperation {
        guard model.panel?.screenID == screenID else { return .copy }
        let id = model.target(at: point)?.id
        if model.hoveredTargetID != id { model.hoveredTargetID = id }
        return .copy
    }

    func dragExited(screenID: String) {
        guard model.panel?.screenID == screenID else { return }
        model.hoverExited()
    }

    func performDrop(screenID: String, urls: [URL], point: CGPoint) -> Bool {
        let target = model.panel?.screenID == screenID ? model.target(at: point) : nil
        return model.drop(urls: urls, on: target?.id)
    }
}
