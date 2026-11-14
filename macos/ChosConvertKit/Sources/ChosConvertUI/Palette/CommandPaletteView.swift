import AppKit
import ChosConvertKit
import SwiftUI

/// ⌘K: a searchable list of intents and navigation. Keyboard-first: type, ↑/↓, Return, Esc.
struct CommandPaletteView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var selection: PaletteCommand.ID?
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 560
    static let listMaxHeight: CGFloat = 340

    init(model: AppModel, query: String = "") {
        self.model = model
        _query = State(initialValue: query)
    }

    var results: [PaletteCommand] { PaletteSearch.filter(query, PaletteCatalog.commands(for: model)) }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true)
                TextField(L.s("palette.placeholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { runSelected(in: results) }
                    // On the field itself: the field editor would otherwise consume ↑/↓.
                    .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                    .onExitCommand { close() }
                    .accessibilityLabel(Text(l: "palette.a11y.search"))
                Text("esc").font(DS.Typography.mono).foregroundStyle(DS.Palette.textTertiary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.s).strokeBorder(DS.Palette.border))
                    .accessibilityHidden(true)
            }
            .padding(DS.Spacing.l)
            Divider()
            if results.isEmpty {
                Text(l: "palette.empty")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: DS.Spacing.xxs) {
                            ForEach(results) { command in
                                PaletteRow(command: command, isSelected: command.id == currentSelection(in: results))
                                    .id(command.id)
                                    .onTapGesture { run(command) }
                                    .onHover { if $0 { selection = command.id } }
                            }
                        }
                        .padding(DS.Spacing.s)
                    }
                    .frame(maxHeight: Self.listMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) { _, id in
                        guard let id else { return }
                        withAnimation(DS.Motion.animation(DS.Motion.fast, reduceMotion: reduceMotion)) { proxy.scrollTo(id) }
                    }
                }
            }
            if !model.readyFiles.isEmpty {
                Divider()
                Text(model.readyFiles.count == 1 ? L.f("palette.footer.one", model.readyFiles[0].fileName)
                                                 : L.f("palette.footer.many", model.readyFiles.count))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.vertical, DS.Spacing.s)
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous).strokeBorder(DS.Palette.border))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onKeyPress(.escape) { close(); return .handled }
        .onChange(of: query) { selection = nil }
        .onAppear { searchFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(l: "palette.a11y"))
        .accessibilityAddTraits(.isModal)
    }

    func currentSelection(in results: [PaletteCommand]) -> PaletteCommand.ID? {
        if let selection, results.contains(where: { $0.id == selection }) { return selection }
        return results.first(where: \.isEnabled)?.id ?? results.first?.id
    }

    func move(_ delta: Int, in results: [PaletteCommand]) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == currentSelection(in: results) } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        selection = results[next].id
    }

    func runSelected(in results: [PaletteCommand]) {
        guard let id = currentSelection(in: results), let command = results.first(where: { $0.id == id }) else { return }
        run(command)
    }

    func run(_ command: PaletteCommand) {
        guard command.isEnabled else { return }
        close()
        switch command.kind {
        case .intent(let intent): model.performPaletteIntent(intent)
        case .navigate(let section): model.section = section
        case .addFiles: model.presentOpenPanel()
        case .settings: openSettings()
        case .toggleEdgeDock: model.settings.edgeDockEnabled.toggle()
        case .clearFinished: model.queue.clearFinished()
        case .cancelAll: model.queue.cancelAll()
        }
    }

    func close() {
        model.isPaletteShown = false
        query = ""
    }
}

struct PaletteRow: View {
    let command: PaletteCommand
    var isSelected: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: command.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected && command.isEnabled ? DS.Palette.onAccent : DS.Palette.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(command.title)
                .font(DS.Typography.body)
                .foregroundStyle(isSelected && command.isEnabled ? DS.Palette.onAccent : DS.Palette.textPrimary)
            Spacer(minLength: DS.Spacing.s)
            if let reason = command.disabledReason {
                Text(reason).font(DS.Typography.caption)
                    .foregroundStyle(isSelected ? DS.Palette.textSecondary : DS.Palette.textTertiary)
            } else if command.isIntent {
                Text(l: "palette.kind.intent").font(DS.Typography.caption)
                    .foregroundStyle(isSelected ? DS.Palette.onAccent.opacity(0.8) : DS.Palette.textTertiary)
            }
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(isSelected ? (command.isEnabled ? DS.Palette.accent : DS.Palette.accentSoft) : Color.clear)
        )
        .opacity(command.isEnabled ? 1 : 0.6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Dimmed backdrop + palette, shown over the main window.
struct CommandPaletteOverlay: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { model.isPaletteShown = false }
                .accessibilityHidden(true)
            CommandPaletteView(model: model)
                .padding(.top, DS.Spacing.xxxl * 2)
        }
    }
}

extension AppModel {
    /// Runs an intent picked in the palette: opens its configurator on the loaded files, or asks
    /// for files first and opens it once they are inspected.
    public func performPaletteIntent(_ intent: PaletteIntent) {
        section = .home
        if files.isEmpty {
            pendingPaletteIntent = intent
            presentOpenPanel()
            if files.isEmpty { pendingPaletteIntent = nil }
            return
        }
        pendingPaletteIntent = intent
        resolvePendingPaletteIntent()
    }

    func resolvePendingPaletteIntent() {
        guard let intent = pendingPaletteIntent, !isInspecting, !readyFiles.isEmpty else { return }
        pendingPaletteIntent = nil
        guard let action = actions.first(where: { $0.id == intent.actionID }) else { return }
        if case .compressVideo = intent, readyFiles.contains(where: { $0.family != .video }) { return }
        activeAction = ActionRequest(action: action, preferredFormat: intent.format)
    }
}
