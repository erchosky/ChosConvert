import AppKit
import ChosConvertKit
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView {
            GeneralSettings(settings: model.settings)
                .tabItem { Label { Text(l: "settings.general") } icon: { Image(systemName: "gearshape") } }
            EdgeDockSettings(settings: model.settings)
                .tabItem { Label { Text(l: "settings.dock") } icon: { Image(systemName: "sidebar.right") } }
            OutputSettings(settings: model.settings)
                .tabItem { Label { Text(l: "settings.output") } icon: { Image(systemName: "folder") } }
            ProcessingSettings(model: model)
                .tabItem { Label { Text(l: "settings.processing") } icon: { Image(systemName: "cpu") } }
            AdvancedSettings(model: model)
                .tabItem { Label { Text(l: "settings.advanced") } icon: { Image(systemName: "wrench.and.screwdriver") } }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Picker(selection: $settings.appearance) {
                ForEach(AppearancePreference.allCases) { Text(l: "appearance.\($0.rawValue)").tag($0) }
            } label: { Text(l: "settings.appearance") }
            Toggle(isOn: $settings.notifyOnCompletion) { Text(l: "settings.notify") }
            Toggle(isOn: $settings.showMenuBarExtra) { Text(l: "settings.menubar") }
            LabeledContent {
                Text(l: "settings.privacy.value")
            } label: { Text(l: "settings.privacy") }
        }
        .formStyle(.grouped)
    }
}

struct EdgeDockSettings: View {
    @Bindable var settings: AppSettings
    @State private var screens: [DockScreen] = []

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.edgeDockEnabled) { Text(l: "settings.dock.enabled") }
                Text(l: "settings.dock.hint").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Section {
                Picker(selection: $settings.edgeDockSide) {
                    Text(l: "settings.dock.side.left").tag(EdgeDockSide.left)
                    Text(l: "settings.dock.side.right").tag(EdgeDockSide.right)
                } label: { Text(l: "settings.dock.side") }
                .pickerStyle(.segmented)
                Picker(selection: $settings.edgeDockSensitivity) {
                    Text(l: "settings.dock.sensitivity.low").tag(EdgeDockSensitivity.low)
                    Text(l: "settings.dock.sensitivity.medium").tag(EdgeDockSensitivity.medium)
                    Text(l: "settings.dock.sensitivity.high").tag(EdgeDockSensitivity.high)
                } label: { Text(l: "settings.dock.sensitivity") }
                .pickerStyle(.segmented)
                Picker(selection: $settings.edgeDockScreens) {
                    Text(l: "settings.dock.screens.all").tag(EdgeDockScreenChoice.all)
                    Text(l: "settings.dock.screens.main").tag(EdgeDockScreenChoice.main)
                    if screens.count > 1 {
                        Divider()
                        ForEach(screens, id: \.id) { screen in
                            Text(verbatim: screen.name).tag(EdgeDockScreenChoice.display(screen.id))
                        }
                    }
                    if case .display(let id) = settings.edgeDockScreens, !screens.contains(where: { $0.id == id }) {
                        Text(l: "settings.dock.screens.disconnected").tag(settings.edgeDockScreens)
                    }
                } label: { Text(l: "settings.dock.screens") }
                Toggle(isOn: $settings.edgeDockHideInFullScreen) { Text(l: "settings.dock.fullscreen") }
                Toggle(isOn: $settings.edgeDockReduceMotion) { Text(l: "settings.dock.motion") }
                Text(l: "settings.dock.motion.hint").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            .disabled(!settings.edgeDockEnabled)
        }
        .formStyle(.grouped)
        .onAppear { screens = DockScreen.current() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = DockScreen.current()
        }
    }
}

struct OutputSettings: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Picker(selection: $settings.outputMode) {
                Text(l: "settings.output.same").tag(OutputLocationMode.sameFolder)
                Text(l: "settings.output.custom").tag(OutputLocationMode.custom)
            } label: { Text(l: "settings.output.location") }
            .pickerStyle(.radioGroup)
            if settings.outputMode == .custom {
                LabeledContent {
                    HStack {
                        Text(settings.customOutputFolder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—")
                            .foregroundStyle(DS.Palette.textSecondary)
                        Button { chooseFolder() } label: { Text(l: "settings.output.choose") }
                    }
                } label: { Text(l: "settings.output.folder") }
            }
            Picker(selection: $settings.collision) {
                Text(l: "collision.rename").tag(CollisionPolicy.rename)
                Text(l: "collision.replace").tag(CollisionPolicy.replace)
                Text(l: "collision.skip").tag(CollisionPolicy.skip)
            } label: { Text(l: "settings.output.collision") }
            Text(l: "settings.output.originals").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
        }
        .formStyle(.grouped)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L.s("settings.output.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.customOutputFolder = url.path
        // Persist sandbox access to the chosen folder.
        Task { await OutputAccess.shared.remember(url) }
    }
}

struct ProcessingSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker(selection: $settings.maxConcurrentJobs) {
                Text(l: "settings.concurrency.auto").tag(0)
                ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
            } label: { Text(l: "settings.concurrency") }
            .onChange(of: settings.maxConcurrentJobs) { _, v in model.queue.maxConcurrentOverride = v > 0 ? v : nil }
            Toggle(isOn: $settings.preferHardwareEncoding) { Text(l: "settings.hardware") }
            Text(l: "settings.hardware.hint").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @Bindable var model: AppModel
    @State private var ffmpegPath = ""

    var body: some View {
        Form {
            Section {
                if let ff = model.capabilities?.ffmpeg {
                    LabeledContent { Text(ff.version) } label: { Text(l: "settings.ffmpeg.version") }
                    LabeledContent { Text(ff.license.uppercased()) } label: { Text(l: "settings.ffmpeg.license") }
                    LabeledContent { Text(ff.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle) } label: {
                        Text(l: "settings.ffmpeg.path")
                    }
                    LabeledContent {
                        Text(ff.hardwareEncoders.map(\.name).joined(separator: ", ").nilIfEmpty ?? "—")
                    } label: { Text(l: "settings.ffmpeg.hw") }
                } else {
                    Text(l: "settings.ffmpeg.none").foregroundStyle(DS.Palette.textSecondary)
                }
                if !CapabilityService.isSandboxed {
                    HStack {
                        TextField(L.s("settings.ffmpeg.custom"), text: $ffmpegPath)
                        Button { apply() } label: { Text(l: "settings.ffmpeg.apply") }
                    }
                }
            } header: { Text(l: "settings.engines") }
            Section {
                LabeledContent { Text(CoreBridge.version) } label: { Text(l: "settings.core.version") }
                if let p = model.capabilities?.platform {
                    LabeledContent { Text("macOS \(p.osVersion) · \(p.arch)") } label: { Text(l: "settings.system") }
                }
                Button { Task { await OutputAccess.shared.forgetAll() } } label: { Text(l: "settings.permissions.reset") }
                Button(role: .destructive) { model.settings.resetAll() } label: { Text(l: "settings.reset") }
            } header: { Text(l: "settings.diagnostics") }
        }
        .formStyle(.grouped)
        .onAppear { ffmpegPath = model.settings.customFFmpegPath ?? "" }
    }

    func apply() {
        model.settings.customFFmpegPath = ffmpegPath.isEmpty ? nil : ffmpegPath
        Task { await model.reloadCapabilities() }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
