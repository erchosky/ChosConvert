import AppKit
import ChosConvertKit
import SwiftUI
import Testing
@testable import ChosConvertUI

/// Renders real app screens offscreen (light + dark) into docs/screenshots.
/// Opt-in: CC_SNAPSHOTS=1 swift test --filter SnapshotRenderer
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CC_SNAPSHOTS"] == "1"))
struct SnapshotRenderer {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let out = root.appendingPathComponent("docs/screenshots")

    func render<V: View>(_ view: V, name: String, size: CGSize) async throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(DS.Palette.surface)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            host.display()
            var rep0: NSBitmapImageRep?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                rep0 = host.bitmapImageRepForCachingDisplay(in: host.bounds)
                if let r = rep0 { host.cacheDisplay(in: host.bounds, to: r) }
            }
            if let rep0, let png = rep0.representation(using: .png, properties: [:]) {
                try png.write(to: Self.out.appendingPathComponent("\(name)-\(suffix).png"))
                window.close()
                continue
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: Self.out.appendingPathComponent("\(name)-\(suffix).png"))
            window.close()
        }
    }

    func model(with fixtures: [String]) async throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: "cc-snap-\(UUID())"))
        let model = AppModel(settings: AppSettings(defaults: defaults))
        await model.bootstrap()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-snap-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (src, name) in fixtures.map({ ($0, $0) }) {
            let dst = dir.appendingPathComponent(name == "video_h264_aac.mov" ? "grabacion.mov" : name)
            try FileManager.default.copyItem(at: AppFlowTests.fixtures.appendingPathComponent(src), to: dst)
            urls.append(dst)
        }
        model.add(urls: urls)
        for _ in 0..<200 where model.isInspecting || model.actions.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(500)) // thumbnails
        return model
    }

    @Test func home() async throws {
        let defaults = try #require(UserDefaults(suiteName: "cc-snap-empty"))
        let empty = AppModel(settings: AppSettings(defaults: defaults))
        try await render(HomeView(model: empty), name: "home-empty", size: CGSize(width: 820, height: 560))
        let video = try await model(with: ["video_h264_aac.mov"])
        try await render(HomeView(model: video), name: "home-video", size: CGSize(width: 820, height: 620))
        let images = try await model(with: ["photo_gps.jpg", "photo.heic", "logo_alpha.png", "large.png"])
        try await render(HomeView(model: images), name: "home-images", size: CGSize(width: 820, height: 720))
    }

    @Test func configurator() async throws {
        let video = try await model(with: ["video_h264_aac.mov"])
        let action = try #require(video.actions.first { $0.id == .makeSmaller })
        try await render(ActionConfiguratorView(model: video, request: ActionRequest(action: action)),
                         name: "configure-make-smaller", size: CGSize(width: 560, height: 600))
        let photo = try await model(with: ["photo_gps.jpg"])
        let privacy = try #require(photo.actions.first { $0.id == .removeLocation })
        try await render(ActionConfiguratorView(model: photo, request: ActionRequest(action: privacy)),
                         name: "configure-remove-location", size: CGSize(width: 560, height: 560))
    }

    /// Edge Dock card over a desktop-like backdrop, in each phase.
    func dockScene(_ dock: EdgeDockModel, settings: AppSettings) -> some View {
        ZStack(alignment: .trailing) {
            LinearGradient(colors: [Color(nsColor: .systemTeal).opacity(0.45), Color(nsColor: .systemIndigo).opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            EdgeDockRootView(model: dock, settings: settings, screenID: "snap")
                .frame(width: EdgeDockGeometry.panelWidth + EdgeDockGeometry.panelInset)
        }
    }

    @Test func edgeDock() async throws {
        let photo = try await model(with: ["photo_gps.jpg"])
        let dock = EdgeDockModel(app: photo)
        dock.dragBegan()
        dock.hoverEntered(screenID: "snap", urls: photo.files.map(\.url), anchorY: 0)
        for _ in 0..<200 where dock.panel?.content != .ready { try await Task.sleep(for: .milliseconds(25)) }
        dock.hoveredTargetID = ActionID.removeLocation.rawValue
        try await render(dockScene(dock, settings: photo.settings), name: "edge-dock-hover", size: CGSize(width: 440, height: 520))

        let video = try await model(with: ["video_h264_aac.mov"])
        let vdock = EdgeDockModel(app: video)
        vdock.dragBegan()
        vdock.hoverEntered(screenID: "snap", urls: video.files.map(\.url), anchorY: 0)
        for _ in 0..<200 where vdock.panel?.content != .ready { try await Task.sleep(for: .milliseconds(25)) }
        vdock.drop(urls: video.files.map(\.url), on: "convert.mp4")
        for _ in 0..<800 where !vdock.allJobsFinished { try await Task.sleep(for: .milliseconds(25)) }
        vdock.isPointerInside = true // keep the card from timing out while rendering
        try await render(dockScene(vdock, settings: video.settings), name: "edge-dock-result", size: CGSize(width: 440, height: 260))

        // The strip as it appears at the screen edge during a drag (magnified backdrop crop).
        let idle = EdgeDockModel(app: video)
        idle.dragBegan()
        try await render(ZStack(alignment: .trailing) {
            LinearGradient(colors: [Color(nsColor: .systemTeal).opacity(0.45), Color(nsColor: .systemIndigo).opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            EdgeDockRootView(model: idle, settings: video.settings, screenID: "snap").frame(width: 6)
        }, name: "edge-dock-strip", size: CGSize(width: 120, height: 360))
    }

    @Test func commandPalette() async throws {
        let video = try await model(with: ["video_h264_aac.mov"])
        try await render(ZStack(alignment: .top) {
            HomeView(model: video)
            CommandPaletteOverlay(model: video)
        }, name: "command-palette", size: CGSize(width: 820, height: 620))
        try await render(ZStack(alignment: .top) {
            HomeView(model: video)
            Color.black.opacity(0.15)
            CommandPaletteView(model: video, query: "compress").padding(.top, DS.Spacing.xxxl * 2)
        }, name: "command-palette-search", size: CGSize(width: 820, height: 620))
    }

    @Test func settingsEdgeDock() async throws {
        let defaults = try #require(UserDefaults(suiteName: "cc-snap-settings-\(UUID())"))
        try await render(EdgeDockSettings(settings: AppSettings(defaults: defaults)), name: "settings-edge-dock",
                         size: CGSize(width: 560, height: 470))
    }

    @Test func queue() async throws {
        let m = try await model(with: ["video_h264_aac.mov", "audio.wav", "renamed_executable.jpg"])
        let files = m.readyFiles
        m.start(.makeSmaller(.balanced), options: AdvancedOptions(), files: files)
        for _ in 0..<400 where !m.queue.items.allSatisfy({ $0.status.isTerminal }) { try await Task.sleep(for: .milliseconds(25)) }
        try await render(QueueView(model: m), name: "queue", size: CGSize(width: 820, height: 360))
        try await render(InspectorView(file: m.files.first), name: "inspector", size: CGSize(width: 320, height: 640))
    }
}
