import AppKit
import ChosConvertKit
import SwiftUI

/// Main window.
public struct RootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Label { Text(l: "nav.home") } icon: { Image(systemName: "square.and.arrow.down") }
                    .tag(AppSection.home)
                Label { Text(l: "nav.queue") } icon: { Image(systemName: "list.bullet.rectangle") }
                    .badge(model.queue.activeCount + model.queue.waitingCount)
                    .tag(AppSection.queue)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            switch model.section {
            case .home: HomeView(model: model)
            case .queue: QueueView(model: model)
            }
        }
        .inspector(isPresented: $model.isInspectorShown) {
            InspectorView(file: model.inspectedFile)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .sheet(item: $model.activeAction) { request in
            ActionConfiguratorView(model: model, request: request)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { chooseFiles() } label: {
                    Label { Text(l: "toolbar.add") } icon: { Image(systemName: "plus") }
                }
                .help(L.s("toolbar.add"))
            }
        }
        .overlay {
            if model.isPaletteShown { CommandPaletteOverlay(model: model) }
        }
        .tint(DS.Palette.accent)
        .task { await model.bootstrap() }
        .task { await installFolderAccessPrompt() }
    }

    func chooseFiles() { model.presentOpenPanel() }

    func installFolderAccessPrompt() async {
        await OutputAccess.shared.setRequestHandler { folder in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = folder
            panel.message = L.f("access.prompt.message", folder.lastPathComponent)
            panel.prompt = L.s("access.prompt.allow")
            return panel.runModal() == .OK ? panel.url : nil
        }
    }
}
