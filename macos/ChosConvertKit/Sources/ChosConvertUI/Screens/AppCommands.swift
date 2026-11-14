import AppKit
import ChosConvertKit
import SwiftUI

/// Menu bar commands for the main window.
public struct AppCommands: Commands {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L.s("menu.add")) { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu(L.s("menu.go")) {
            Button(L.s("nav.home")) { model.section = .home }
                .keyboardShortcut("1", modifiers: .command)
            Button(L.s("nav.queue")) { model.section = .queue }
                .keyboardShortcut("2", modifiers: .command)
            Button(L.s("palette.menu")) {
                if model.isPaletteShown {
                    model.isPaletteShown = false
                } else {
                    model.showMainWindow()
                    model.isPaletteShown = true
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button(L.s("queue.cancel.all")) { model.queue.cancelAll() }
                .keyboardShortcut(".", modifiers: .command)
        }
    }
}

extension AppModel {
    /// Shows the standard open panel for files and folders.
    public func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = L.s("home.drop.choose.prompt")
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }
}
