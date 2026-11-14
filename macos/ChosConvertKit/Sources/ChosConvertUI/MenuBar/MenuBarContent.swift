import AppKit
import ChosConvertKit
import SwiftUI

/// Menu of the menu bar extra: open the app, recent results, Edge Dock switch, settings, quit.
public struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        @Bindable var settings = model.settings
        Button(L.s("menubar.open")) { model.showMainWindow() }
        let running = model.queue.activeCount + model.queue.waitingCount
        if running > 0 {
            Button(L.f("menubar.running", running)) { model.showMainWindow(.queue) }
        }
        Divider()
        Section(L.s("menubar.recent")) {
            if model.recentResults.isEmpty {
                Text(l: "menubar.recent.empty")
            } else {
                ForEach(model.recentResults.prefix(5)) { result in
                    Button(result.url.lastPathComponent) {
                        NSWorkspace.shared.activateFileViewerSelecting([result.url])
                    }
                    .help(L.s("result.reveal"))
                }
            }
        }
        Divider()
        Toggle(L.s("menubar.dock"), isOn: $settings.edgeDockEnabled)
        Divider()
        Button(L.s("menubar.settings")) {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button(L.s("menubar.quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

/// The status item's icon. Shows activity while jobs run.
public struct MenuBarLabel: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let busy = model.queue.activeCount > 0
        Image(systemName: busy ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
            .accessibilityLabel(Text(l: busy ? "menubar.a11y.busy" : "menubar.a11y"))
    }
}
