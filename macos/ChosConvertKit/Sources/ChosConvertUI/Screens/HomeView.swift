import AppKit
import ChosConvertKit
import SwiftUI
import UniformTypeIdentifiers

extension ActionID {
    var symbol: String {
        switch self {
        case .makeSmaller: "arrow.down.right.and.arrow.up.left"
        case .targetSize: "scope"
        case .convert: "arrow.triangle.2.circlepath"
        case .extractAudio: "waveform"
        case .createGif: "square.stack.3d.forward.dottedline"
        case .resize: "aspectratio"
        case .webOptimize: "globe"
        case .removeMetadata: "eye.slash"
        case .removeLocation: "location.slash"
        }
    }
    var titleKey: String { "action.\(rawValue).title" }
    var subtitleKey: String { "action.\(rawValue).subtitle" }
}

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        Group {
            if model.files.isEmpty {
                DropZoneView(isTargeted: isTargeted, onChoose: chooseFiles)
                    .padding(DS.Spacing.xl)
            } else {
                SelectionView(model: model, isTargeted: isTargeted)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.add(urls: files)
            return true
        } isTargeted: { isTargeted = $0 }
        .navigationTitle(Text(l: "nav.home"))
    }

    func chooseFiles() { model.presentOpenPanel() }
}

struct SelectionView: View {
    @Bindable var model: AppModel
    var isTargeted: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                header
                FileListView(model: model)
                actionsSection
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.xl).strokeBorder(DS.Palette.accent, lineWidth: 2)
                    .padding(DS.Spacing.s).allowsHitTesting(false)
            }
        }
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(model.files.count == 1 ? L.s("home.selection.one") : L.f("home.selection.many", model.files.count))
                    .font(DS.Typography.title)
                if model.isInspecting {
                    Label { Text(l: "home.inspecting") } icon: { ProgressView().controlSize(.small) }
                        .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            Spacer()
            Button { model.isInspectorShown.toggle() } label: {
                Label { Text(l: "home.inspector") } icon: { Image(systemName: "info.circle") }
            }
            .keyboardShortcut("i", modifiers: .command)
            Button(role: .destructive) { model.clearFiles() } label: { Text(l: "home.clear") }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    @ViewBuilder var actionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text(l: "home.actions.title").font(DS.Typography.headline)
            if model.actions.isEmpty {
                Text(l: model.isInspecting ? "home.actions.waiting" : "home.actions.none")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Size.actionTileMinWidth), spacing: DS.Spacing.m)],
                          spacing: DS.Spacing.m) {
                    ForEach(model.actions) { action in
                        Button { model.activeAction = ActionRequest(action: action) } label: {
                            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                                Image(systemName: action.id.symbol)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(DS.Palette.accent)
                                    .frame(height: 22)
                                Text(l: action.id.titleKey).font(DS.Typography.headline).foregroundStyle(DS.Palette.textPrimary)
                                Text(l: action.id.subtitleKey).font(DS.Typography.caption)
                                    .foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                            }
                        }
                        .buttonStyle(ActionTileStyle())
                        .accessibilityLabel(Text(l: action.id.titleKey))
                        .accessibilityHint(Text(l: action.id.subtitleKey))
                    }
                }
            }
        }
    }
}

struct FileListView: View {
    @Bindable var model: AppModel
    static let collapsedLimit = 8
    @State private var expanded = false

    var body: some View {
        let shown = expanded ? model.files : Array(model.files.prefix(Self.collapsedLimit))
        VStack(spacing: 0) {
            ForEach(shown) { file in
                FileRow(file: file, isSelected: model.inspectedFileID == file.id) {
                    model.inspectedFileID = file.id
                    model.isInspectorShown = true
                } onRemove: { model.remove(file) }
                if file.id != shown.last?.id { Divider().padding(.leading, DS.Size.thumbnail + DS.Spacing.l) }
            }
            if model.files.count > Self.collapsedLimit {
                Divider()
                Button { expanded.toggle() } label: {
                    Text(expanded ? L.s("home.files.less") : L.f("home.files.more", model.files.count - Self.collapsedLimit))
                }
                .buttonStyle(.link)
                .padding(.vertical, DS.Spacing.s)
            }
        }
        .card(padding: DS.Spacing.s)
    }
}

struct FileRow: View {
    let file: DroppedFile
    var isSelected: Bool
    var onSelect: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            FileIcon(thumbnail: file.thumbnail, family: file.info?.family ?? .unknown)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.s) {
                    Text(file.url.lastPathComponent).font(DS.Typography.body).lineLimit(1).truncationMode(.middle)
                    if let info = file.info {
                        FormatBadge(text: info.detection.format.displayName)
                        if info.detection.isExtensionMismatch {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(DS.Palette.warning)
                                .help(L.s("home.file.mismatch"))
                                .accessibilityLabel(Text(l: "home.file.mismatch"))
                        }
                        if info.hasSensitiveMetadata {
                            Image(systemName: "location.fill").font(.caption2).foregroundStyle(DS.Palette.textTertiary)
                                .help(L.s("home.file.personal"))
                                .accessibilityLabel(Text(l: "home.file.personal"))
                        }
                    }
                }
                switch file.state {
                case .inspecting:
                    Text(l: "home.file.inspecting").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                case .ready(let info):
                    Text(Fmt.summary(info).joined(separator: " · "))
                        .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                case .failed(let error):
                    Text(L.error(error)).font(DS.Typography.caption).foregroundStyle(DS.Palette.danger).lineLimit(2)
                }
            }
            Spacer(minLength: DS.Spacing.s)
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Palette.textTertiary)
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel(Text(l: "home.file.remove"))
        }
        .padding(DS.Spacing.s)
        .background(isSelected ? DS.Palette.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.m))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(l: "home.file.remove"), onRemove)
    }
}
