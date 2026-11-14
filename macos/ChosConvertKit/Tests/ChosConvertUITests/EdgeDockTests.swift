@testable import ChosConvertKit
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ChosConvertUI

// MARK: Geometry (synthetic multi-monitor arrangements)

@Suite struct EdgeDockGeometryTests {
    /// 1440×900 built-in Retina display (scale 2) holding the menu bar, at the origin.
    static let laptop = DockScreen(id: "laptop", displayID: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                   visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805), scale: 2, isMain: true)
    /// 2560×1440 external display (scale 1) to the right, offset 200 pt lower and taller.
    static let external = DockScreen(id: "external", displayID: 2, name: "Studio", frame: CGRect(x: 1440, y: -200, width: 2560, height: 1440),
                                     visibleFrame: CGRect(x: 1440, y: -200, width: 2560, height: 1415), scale: 1, isMain: false)
    /// A display stacked above the laptop.
    static let above = DockScreen(id: "above", displayID: 3, name: "Above", frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1055), scale: 1, isMain: false)

    @Test func screenChoice() {
        let all = [Self.laptop, Self.external]
        #expect(EdgeDockGeometry.screens(for: .all, in: all).map(\.id) == ["laptop", "external"])
        #expect(EdgeDockGeometry.screens(for: .main, in: all).map(\.id) == ["laptop"])
        #expect(EdgeDockGeometry.screens(for: .display("external"), in: all).map(\.id) == ["external"])
        // An unplugged remembered display falls back to the main one instead of disappearing.
        #expect(EdgeDockGeometry.screens(for: .display("gone"), in: all).map(\.id) == ["laptop"])
    }

    @Test func screenChoiceRoundTrips() {
        for choice in [EdgeDockScreenChoice.all, .main, .display("37D8832A-2D66-02CA-B9F7-8F30A301B230")] {
            #expect(EdgeDockScreenChoice(rawValue: choice.rawValue) == choice)
        }
        #expect(EdgeDockScreenChoice(rawValue: "garbage") == .all)
        #expect(EdgeDockScreenChoice(rawValue: "display:") == .all)
    }

    @Test func singleDisplayUsesTheWholeVisibleEdge() throws {
        let seg = try #require(EdgeDockGeometry.outerSegment(of: Self.laptop, side: .right, among: [Self.laptop]))
        #expect(seg == 70...875)
        let strip = try #require(EdgeDockGeometry.stripFrame(for: Self.laptop, side: .right, width: 6, among: [Self.laptop]))
        #expect(strip == CGRect(x: 1434, y: 70, width: 6, height: 805))
        let left = try #require(EdgeDockGeometry.stripFrame(for: Self.laptop, side: .left, width: 3, among: [Self.laptop]))
        #expect(left.minX == 0 && left.width == 3)
    }

    @Test func interiorEdgesGetNoStrip() {
        // The laptop's right edge is entirely shared with the taller external display.
        #expect(EdgeDockGeometry.outerSegment(of: Self.laptop, side: .right, among: [Self.laptop, Self.external]) == nil)
        // Its left edge is free.
        #expect(EdgeDockGeometry.outerSegment(of: Self.laptop, side: .left, among: [Self.laptop, Self.external]) != nil)
        // The external display's right edge is free across its full visible height.
        #expect(EdgeDockGeometry.outerSegment(of: Self.external, side: .right, among: [Self.laptop, Self.external]) == -200...1215)
    }

    @Test func partiallySharedEdgeKeepsTheLongestFreePart() throws {
        // External's left edge touches the laptop for y 0…900: free parts are -200…0 and 900…1215.
        let seg = try #require(EdgeDockGeometry.outerSegment(of: Self.external, side: .left, among: [Self.laptop, Self.external]))
        #expect(seg == 900...1215)
        let strip = try #require(EdgeDockGeometry.stripFrame(for: Self.external, side: .left, width: 12, among: [Self.laptop, Self.external]))
        #expect(strip == CGRect(x: 1440, y: 900, width: 12, height: 315))
    }

    @Test func verticallyStackedDisplaysKeepBothSideEdges() {
        let screens = [Self.laptop, Self.above]
        for side in EdgeDockSide.allCases {
            #expect(EdgeDockGeometry.outerSegment(of: Self.laptop, side: side, among: screens) != nil)
            #expect(EdgeDockGeometry.outerSegment(of: Self.above, side: side, among: screens) != nil)
        }
    }

    @Test func stripWidthIsClamped() throws {
        let strip = try #require(EdgeDockGeometry.stripFrame(for: Self.laptop, side: .right, width: 500, among: [Self.laptop]))
        #expect(strip.width == 40)
        #expect(EdgeDockSensitivity.allCases.map(\.stripWidth) == [3, 6, 12])
    }

    @Test func panelReachesTheEdgeAndStaysOnScreen() {
        let area = Self.laptop.visibleFrame
        let mid = EdgeDockGeometry.panelFrame(for: Self.laptop, side: .right, anchorY: 500, height: 300)
        #expect(mid.maxX == area.maxX, "the window touches the edge so the pointer stays inside after expanding")
        #expect(mid.width == EdgeDockGeometry.panelWidth + EdgeDockGeometry.panelInset)
        #expect(mid.midY == 500)
        let low = EdgeDockGeometry.panelFrame(for: Self.laptop, side: .left, anchorY: 0, height: 300)
        #expect(low.minX == area.minX)
        #expect(low.minY == area.minY + EdgeDockGeometry.panelInset)
        let tall = EdgeDockGeometry.panelFrame(for: Self.laptop, side: .right, anchorY: 870, height: 5000)
        #expect(tall.height == EdgeDockGeometry.panelMaxHeight)
        #expect(tall.maxY <= area.maxY - EdgeDockGeometry.panelInset)
        // Mixed scale: the same point-based rule on the 1× external display.
        let ext = EdgeDockGeometry.panelFrame(for: Self.external, side: .right, anchorY: 0, height: 200)
        #expect(ext.maxX == Self.external.visibleFrame.maxX && ext.midY == 0)
    }

    @Test func fullScreenDetection() {
        let primaryHeight: CGFloat = 900
        // External display in CG coordinates: x 1440, y = 900 - (−200 + 1440) = −340.
        let fullscreenOnExternal = WindowSnapshot(bounds: CGRect(x: 1440, y: -340, width: 2560, height: 1440), layer: 0, ownerPID: 42, alpha: 1)
        let ordinary = WindowSnapshot(bounds: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0, ownerPID: 42, alpha: 1)
        let menuBarLevel = WindowSnapshot(bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 25, ownerPID: 7, alpha: 1)
        let windows = [fullscreenOnExternal, ordinary, menuBarLevel]
        #expect(EdgeDockGeometry.isFullScreen(Self.external, windows: windows, primaryHeight: primaryHeight, ownPID: 1))
        #expect(!EdgeDockGeometry.isFullScreen(Self.laptop, windows: windows, primaryHeight: primaryHeight, ownPID: 1))
        // Our own windows never count.
        #expect(!EdgeDockGeometry.isFullScreen(Self.external, windows: windows, primaryHeight: primaryHeight, ownPID: 42))
    }
}

// MARK: Drag session detection

@MainActor
final class FakeDragSignals: DragSignals {
    var isPrimaryButtonDown = false
    var count = 0
    var carriesFiles = true
    var countReads = 0
    var dragChangeCount: Int { countReads += 1; return count }
    var dragCarriesFiles: Bool { carriesFiles }
}

@MainActor @Suite struct DragSessionWatcherTests {
    func make() -> (DragSessionWatcher, FakeDragSignals, () -> [DragSessionWatcher.Event]) {
        let signals = FakeDragSignals()
        let watcher = DragSessionWatcher(signals: signals)
        var events: [DragSessionWatcher.Event] = []
        watcher.onEvent = { events.append($0) }
        return (watcher, signals, { events })
    }

    @Test func fileDragBeginsAndEnds() {
        let (watcher, s, events) = make()
        watcher.tick()
        s.isPrimaryButtonDown = true
        watcher.tick()
        #expect(events().isEmpty, "a click is not a drag")
        s.count += 1 // Finder starts a drag
        watcher.tick()
        #expect(events() == [.began])
        #expect(watcher.isDragging)
        watcher.tick()
        s.isPrimaryButtonDown = false
        watcher.tick()
        #expect(events() == [.began, .ended])
    }

    @Test func nonFileDragsAreIgnored() {
        let (watcher, s, events) = make()
        s.carriesFiles = false
        s.isPrimaryButtonDown = true
        s.count += 1
        watcher.tick()
        #expect(events().isEmpty)
    }

    @Test func idleCostsNoPasteboardReads() {
        let (watcher, s, _) = make()
        let before = s.countReads
        for _ in 0..<50 { watcher.tick() }
        #expect(s.countReads == before)
    }

    @Test func dragFinishedBetweenSamplesDoesNotFireOnNextClick() {
        let (watcher, s, events) = make()
        s.isPrimaryButtonDown = true
        watcher.tick()
        // A very fast drag starts and ends between two samples.
        s.count += 1
        s.isPrimaryButtonDown = false
        watcher.tick()
        // The next ordinary click must not be taken for a drag.
        s.isPrimaryButtonDown = true
        watcher.tick()
        #expect(events().isEmpty)
    }

    @Test func stopEndsAnActiveSession() {
        let (watcher, s, events) = make()
        s.isPrimaryButtonDown = true
        s.count += 1
        watcher.tick()
        watcher.stop()
        #expect(events() == [.began, .ended])
    }
}

// MARK: Targets and default intents

@Suite struct DockTargetsTests {
    static let detection = Detection(format: .heic, family: .image, mime: "image/heic", extension: "heic",
                                     extensionMatches: true, confidence: "high", sizeBytes: 1000, warnings: nil)

    func info(_ family: FileFamily, duration: Double? = nil) -> MediaInfo {
        MediaInfo(path: "/tmp/x", fileName: "x", sizeBytes: 1000, detection: Self.detection, family: family,
                  durationS: duration, inspector: "test")
    }

    @Test func imageRows() throws {
        let actions = [
            SmartAction(id: .makeSmaller, primary: true, formats: nil),
            SmartAction(id: .convert, primary: true, formats: [.jpeg, .png, .webp, .heic, .avif, .tiff]),
            SmartAction(id: .resize, primary: false, formats: nil),
            SmartAction(id: .removeLocation, primary: true, formats: nil),
        ]
        let rows = DockTargets.rows(for: actions, files: [info(.image)])
        #expect(rows.map(\.action) == [.makeSmaller, .convert, .removeLocation, .resize], "primary actions first")
        let convert = try #require(rows.first { $0.action == .convert })
        #expect(convert.targets.map(\.label) == [FileFormat.webp, .jpeg, .png, .heic].map(\.displayName), "preferred formats first, at most 4")
        #expect(convert.targets.first?.kind == .run(.convert(.webp)))
        #expect(rows.first { $0.action == .resize }?.targets.first?.kind == .run(.resize(maxDimension: 1920)))
        #expect(rows.first { $0.action == .removeLocation }?.targets.first?.kind == .run(.removeMetadata(.location)))
    }

    @Test func videoDefaults() throws {
        let actions = [
            SmartAction(id: .targetSize, primary: true, formats: nil),
            SmartAction(id: .extractAudio, primary: true, formats: [.m4a, .mp3]),
            SmartAction(id: .createGif, primary: false, formats: nil),
            SmartAction(id: .resize, primary: false, formats: nil),
        ]
        let rows = DockTargets.rows(for: actions, files: [info(.video, duration: 3), info(.video, duration: 40)])
        let target = try #require(rows.first { $0.action == .targetSize })
        #expect(target.targets.map(\.kind) == [.run(.targetSize(bytes: 10_000_000)), .run(.targetSize(bytes: 25_000_000))])
        #expect(rows.first { $0.action == .extractAudio }?.targets.first?.kind == .run(.extractAudio(nil)), "keeps the original audio")
        #expect(rows.first { $0.action == .createGif }?.targets.first?.kind
                == .run(.createGif(startS: 0, durationS: 3, width: 480, fps: 12)), "GIF fits the shortest clip")
        #expect(rows.first { $0.action == .resize }?.targets.first?.kind == .run(.resize(maxDimension: 1080)))
    }

    @Test func targetIDsAreUnique() {
        let actions = ActionID.allCases.map { SmartAction(id: $0, primary: true, formats: [.mp4, .mov, .webm]) }
        let rows = DockTargets.rows(for: actions, files: [info(.video, duration: 10)])
        let ids = rows.flatMap(\.targets).map(\.id) + [DockTargets.openInAppID]
        #expect(Set(ids).count == ids.count)
    }
}

// MARK: Model flow against the real core and engines

@MainActor @Suite(.serialized) struct EdgeDockModelTests {
    func makeDock(copying names: [String]) async throws -> (EdgeDockModel, AppModel, [URL]) {
        let (app, dir) = try AppFlowTests().makeModel()
        var urls: [URL] = []
        for name in names {
            let dst = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(at: AppFlowTests.fixtures.appendingPathComponent(name), to: dst)
            urls.append(dst)
        }
        // Deliberately no bootstrap: the dock must work before the main window ever appeared.
        return (EdgeDockModel(app: app), app, urls)
    }

    func waitUntil(_ timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        try await AppFlowTests().waitUntil(timeout, condition)
    }

    @Test func hoverShowsActionsAndDropStartsTheJob() async throws {
        let (dock, app, urls) = try await makeDock(copying: ["photo_gps.jpg"])
        dock.dragBegan()
        #expect(dock.isDragActive)
        dock.hoverEntered(screenID: "s1", urls: urls, anchorY: 400)
        #expect(dock.panel?.content == .reading)
        try await waitUntil { dock.panel?.content == .ready }
        let ids = Set(dock.targets.map(\.id))
        #expect(ids.contains("convert.webp"))
        #expect(ids.contains(ActionID.removeLocation.rawValue), "GPS detected → privacy action offered")
        #expect(!ids.contains(ActionID.extractAudio.rawValue))

        // Hit-testing uses the frames the SwiftUI rows report.
        dock.targetFrames = ["convert.webp": CGRect(x: 10, y: 100, width: 60, height: 24)]
        #expect(dock.target(at: CGPoint(x: 20, y: 110))?.id == "convert.webp")
        #expect(dock.target(at: CGPoint(x: 200, y: 110)) == nil)

        #expect(dock.drop(urls: urls, on: "convert.webp"))
        #expect(dock.panel?.content == .working)
        #expect(app.section == .home, "the dock never navigates the main window")
        let item = try #require(dock.jobs.first)
        try await waitUntil { item.status.isTerminal }
        #expect(item.status == .completed, "\(String(describing: item.error))")
        #expect(item.outcome?.outputURL?.pathExtension == "webp")
        #expect(app.queue.items.contains { $0.id == item.id }, "same JobQueue as the main window")
        #expect(app.recentResults.first?.url == item.outcome?.outputURL)
        dock.dragEnded()
        try await Task.sleep(for: .milliseconds(400))
        #expect(dock.panel?.content == .working, "the result card outlives the drag")
    }

    @Test func dropOnPanelHoldsFilesForAClick() async throws {
        let (dock, _, urls) = try await makeDock(copying: ["audio.wav"])
        dock.dragBegan()
        dock.hoverEntered(screenID: "s1", urls: urls, anchorY: 400)
        #expect(dock.drop(urls: urls, on: nil))
        #expect(dock.panel?.content == .held)
        try await waitUntil { !dock.rows.isEmpty }
        let smaller = try #require(dock.targets.first { $0.id == ActionID.makeSmaller.rawValue })
        dock.run(smaller)
        #expect(dock.panel?.content == .working)
        let item = try #require(dock.jobs.first)
        try await waitUntil { item.status.isTerminal }
        #expect(item.status == .completed)
    }

    @Test func leavingWithoutDroppingCollapses() async throws {
        let (dock, _, urls) = try await makeDock(copying: ["photo.heic"])
        dock.dragBegan()
        dock.hoverEntered(screenID: "s1", urls: urls, anchorY: 100)
        try await waitUntil { dock.panel?.content == .ready }
        dock.hoverExited()
        #expect(dock.panel != nil, "brief exits don't flicker")
        dock.hoverEntered(screenID: "s1", urls: urls, anchorY: 100)
        #expect(dock.panel?.content == .ready, "re-entering reuses this drag's inspection")
        dock.hoverExited()
        try await Task.sleep(for: .milliseconds(400))
        #expect(dock.panel == nil)
        dock.dragEnded()
        #expect(!dock.isDragActive)
    }

    @Test func unsupportedAndTooManyFiles() async throws {
        let (dock, _, urls) = try await makeDock(copying: ["renamed_executable.jpg"])
        dock.dragBegan()
        dock.hoverEntered(screenID: "s1", urls: urls, anchorY: 100)
        try await waitUntil { dock.panel?.content == .unavailable }
        #expect(dock.notice != nil)
        #expect(dock.target(at: .zero) == nil)

        // A folder of 30 images: more than the dock inspects while hovering.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-many-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<30 {
            try FileManager.default.copyItem(at: AppFlowTests.fixtures.appendingPathComponent("logo_alpha.png"),
                                             to: dir.appendingPathComponent("logo \(i).png"))
        }
        dock.hoverEntered(screenID: "s1", urls: [dir], anchorY: 100)
        #expect(dock.panel?.content == .unavailable)
        #expect(dock.notice?.contains("30") == true)
    }
}

// MARK: Real panels (window server, no real drag). Briefly shows a strip/panel at the screen edge.

@MainActor @Suite(.serialized) struct EdgeDockControllerTests {
    @Test(.enabled(if: !NSScreen.screens.isEmpty)) func panelsFollowTheDragSession() async throws {
        let (app, dir) = try AppFlowTests().makeModel()
        let photo = dir.appendingPathComponent("photo.heic")
        try FileManager.default.copyItem(at: AppFlowTests.fixtures.appendingPathComponent("photo.heic"), to: photo)
        let signals = FakeDragSignals()
        let watcher = DragSessionWatcher(signals: signals)
        let controller = EdgeDockController(model: EdgeDockModel(app: app), settings: app.settings, watcher: watcher)
        controller.start()
        defer { app.settings.edgeDockEnabled = false }
        func dockPanels() -> [EdgeDockPanel] { NSApp.windows.compactMap { $0 as? EdgeDockPanel } }
        func visible() -> [EdgeDockPanel] { dockPanels().filter(\.isVisible) }

        #expect(!dockPanels().isEmpty, "one panel per eligible display")
        #expect(visible().isEmpty, "nothing on screen until a file drag starts")
        let first = try #require(dockPanels().first)
        #expect(first.styleMask.contains(.nonactivatingPanel))
        #expect(first.collectionBehavior.contains(.canJoinAllSpaces) && first.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(first.contentView is EdgeDockDropView)
        #expect(first.contentView?.registeredDraggedTypes.contains(.fileURL) == true)

        // A file drag starts somewhere.
        signals.isPrimaryButtonDown = true
        signals.count += 1
        watcher.tick()
        try await AppFlowTests().waitUntil(.seconds(5)) { !visible().isEmpty }
        let strip = try #require(visible().first)
        #expect(strip.frame.width == CGFloat(app.settings.edgeDockSensitivity.stripWidth))

        // Hover over that strip: it expands into the panel at the same edge.
        let screenID = strip.screenID
        controller.dragEntered(screenID: screenID, urls: [photo], screenPoint: CGPoint(x: strip.frame.maxX - 1, y: strip.frame.midY))
        try await AppFlowTests().waitUntil { controller.model.panel?.content == .ready }
        try await AppFlowTests().waitUntil(.seconds(5)) { strip.frame.width > 100 }
        #expect(abs(strip.frame.maxX - (NSScreen.screens.first { DockScreen($0, isMain: false)?.id == screenID }?.visibleFrame.maxX ?? 0)) < 1)

        // Moving the side setting re-lays out the strips.
        controller.dragExited(screenID: screenID)
        try await Task.sleep(for: .milliseconds(400))
        app.settings.edgeDockSide = .left
        try await AppFlowTests().waitUntil(.seconds(5)) {
            visible().allSatisfy { p in NSScreen.screens.contains { abs($0.visibleFrame.minX - p.frame.minX) < 1 } }
        }

        // Release: strips go away.
        signals.isPrimaryButtonDown = false
        watcher.tick()
        try await AppFlowTests().waitUntil(.seconds(5)) { visible().isEmpty }

        // Disabling removes the panels entirely.
        app.settings.edgeDockEnabled = false
        try await AppFlowTests().waitUntil(.seconds(5)) { dockPanels().allSatisfy { !$0.isVisible } }
        app.settings.edgeDockSide = .right
    }
}

// MARK: Settings

@MainActor @Suite struct EdgeDockSettingsTests {
    @Test func persistAndReset() throws {
        let suite = "cc-dock-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.edgeDockEnabled && settings.edgeDockSide == .right && settings.edgeDockSensitivity == .medium)
        #expect(settings.edgeDockScreens == .all && settings.edgeDockHideInFullScreen && !settings.edgeDockReduceMotion)
        settings.edgeDockEnabled = false
        settings.edgeDockSide = .left
        settings.edgeDockSensitivity = .high
        settings.edgeDockScreens = .display("ABC")
        settings.edgeDockHideInFullScreen = false
        settings.edgeDockReduceMotion = true
        settings.showMenuBarExtra = false
        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.edgeDockEnabled && reloaded.edgeDockSide == .left && reloaded.edgeDockSensitivity == .high)
        #expect(reloaded.edgeDockScreens == .display("ABC") && !reloaded.edgeDockHideInFullScreen && reloaded.edgeDockReduceMotion)
        #expect(!reloaded.showMenuBarExtra)
        reloaded.resetAll()
        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.edgeDockEnabled && fresh.edgeDockSide == .right && fresh.showMenuBarExtra)
    }
}
