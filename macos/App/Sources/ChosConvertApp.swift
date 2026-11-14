import AppKit
import ChosConvertKit
import ChosConvertUI
import SwiftUI

@main
struct ChosConvertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model
        Window(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "ChosConvert", id: "main") {
            RootView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .modifier(InstallWindowOpener(model: model))
                .onAppear { AppearanceController.apply(model.settings.appearance) }
                .onChange(of: model.settings.appearance) { _, new in AppearanceController.apply(new) }
        }
        .defaultSize(width: 980, height: 680)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBarExtra },
                                         set: { model.settings.showMenuBarExtra = $0 })) {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
                .modifier(InstallWindowOpener(model: model))
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Hands SwiftUI's `openWindow` to the model so AppKit surfaces (Edge Dock, menu bar,
/// notifications) can bring the main window back after it was closed.
private struct InstallWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow
            model.mainWindowOpener = { open(id: "main") }
        }
    }
}

/// Owns the app-wide model so it exists before any window: the Edge Dock, menu bar extra and
/// Finder "Open With" all work without opening the main window first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var edgeDock: EdgeDockController?

    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls: urls)
        model.showMainWindow(.home)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceController.apply(model.settings.appearance)
        Task { await model.bootstrap() }
        let dock = EdgeDockController(app: model)
        dock.start()
        edgeDock = dock
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum AppearanceController {
    @MainActor static func apply(_ pref: AppearancePreference) {
        switch pref {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
