import AppKit
import ChosConvertKit
import SwiftUI

enum EdgeDockSpace {
    static let name = "edge-dock"
}

/// Root of each Edge Dock panel: the thin strip during a drag, or the expanded card when this
/// panel's display hosts it.
struct EdgeDockRootView: View {
    let model: EdgeDockModel
    let settings: AppSettings
    let screenID: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var reduceMotion: Bool { systemReduceMotion || settings.edgeDockReduceMotion }
    var side: EdgeDockSide { settings.edgeDockSide }
    var edgeAlignment: Alignment { side == .right ? .trailing : .leading }

    var body: some View {
        ZStack(alignment: edgeAlignment) {
            if let panel = model.panel, panel.screenID == screenID {
                EdgeDockCard(model: model, content: panel.content)
                    .frame(width: EdgeDockGeometry.panelWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        let h = height.rounded(.up)
                        if abs(model.cardHeight - h) > 0.5 { model.cardHeight = h }
                    }
                    .padding(side == .right ? .trailing : .leading, EdgeDockGeometry.panelInset)
                    .transition(reduceMotion ? .identity : .move(edge: side == .right ? .trailing : .leading).combined(with: .opacity))
            } else if model.isDragActive {
                EdgeStripView(side: side, reduceMotion: reduceMotion)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: edgeAlignment.horizontal, vertical: .top))
        .coordinateSpace(.named(EdgeDockSpace.name))
        .animation(DS.Motion.animation(DS.Motion.standard, reduceMotion: reduceMotion), value: model.panel?.content)
        .animation(DS.Motion.animation(DS.Motion.fast, reduceMotion: reduceMotion), value: model.hoveredTargetID)
        .environment(\.edgeDockReduceMotion, reduceMotion)
    }
}

private struct EdgeDockReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct DockTargetHotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var edgeDockReduceMotion: Bool {
        get { self[EdgeDockReduceMotionKey.self] }
        set { self[EdgeDockReduceMotionKey.self] = newValue }
    }

    /// The enclosing dock target is under the dragged files (drawn on an accent fill).
    var dockTargetHot: Bool {
        get { self[DockTargetHotKey.self] }
        set { self[DockTargetHotKey.self] = newValue }
    }
}

/// The ultra-thin edge indicator shown while a file drag is in progress.
struct EdgeStripView: View {
    var side: EdgeDockSide
    var reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        // The window is the hit area; the glow is a slim line hugging the screen edge.
        ZStack(alignment: side == .right ? .trailing : .leading) {
            // Near-transparent fill: keeps the whole strip a drop target without being visible.
            Rectangle().fill(DS.Palette.accent.opacity(0.02))
            Capsule()
                .fill(LinearGradient(colors: [DS.Palette.accent.opacity(0), DS.Palette.accent, DS.Palette.accent.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 3)
                .opacity(pulse ? 1 : 0.55)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(l: "dock.a11y.strip"))
    }
}

/// The expanded panel: header, then content for the current phase.
struct EdgeDockCard: View {
    let model: EdgeDockModel
    let content: EdgeDockModel.Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            header
            switch content {
            case .reading:
                Label { Text(l: "dock.reading") } icon: { ProgressView().controlSize(.small) }
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.vertical, DS.Spacing.s)
            case .ready, .held:
                if model.rows.isEmpty {
                    // `.held` while the dropped files are still being read.
                    Label { Text(l: "dock.reading") } icon: { ProgressView().controlSize(.small) }
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Palette.textSecondary)
                    if let notice = model.notice { noticeText(notice) }
                } else {
                    actionList
                    if let notice = model.notice { noticeText(notice) }
                }
                footer
            case .unavailable:
                if let notice = model.notice { noticeText(notice) }
                footer
            case .working:
                EdgeDockJobsView(model: model)
            }
        }
        .padding(DS.Spacing.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous).strokeBorder(DS.Palette.border.opacity(0.7)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(.vertical, DS.Spacing.l) // room for the shadow inside the transparent window
        .onHover { model.isPointerInside = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(l: "dock.a11y.panel"))
    }

    var headerTitle: String {
        if content == .working {
            return model.allJobsFinished ? L.s("dock.working.done") : L.s("dock.working.title")
        }
        let count = model.files.isEmpty ? model.urls.count : model.files.count
        if count == 1, let name = model.files.first?.fileName ?? model.urls.first?.lastPathComponent { return name }
        return L.f("home.selection.many", count)
    }

    var headerSubtitle: String? {
        guard content != .working, !model.files.isEmpty else { return nil }
        let total = model.files.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        if model.files.count == 1, let f = model.files.first {
            return ([f.detection.format.displayName] + Fmt.summary(f).suffix(2)).joined(separator: " · ")
        }
        return Fmt.bytes(total)
    }

    var family: FileFamily {
        let families = Set(model.files.map(\.family))
        return families.count == 1 ? (families.first ?? .unknown) : .unknown
    }

    var headerSymbol: String {
        guard content == .working else { return family.symbol }
        guard model.allJobsFinished else { return "arrow.triangle.2.circlepath" }
        return model.jobs.contains { $0.status == .completed } ? "checkmark.circle" : "exclamationmark.circle"
    }

    var headerTint: Color {
        guard content == .working else { return DS.Palette.family(family.tint) }
        guard model.allJobsFinished else { return DS.Palette.accent }
        return model.jobs.contains { $0.status == .completed } ? DS.Palette.success : DS.Palette.warning
    }

    var header: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: headerSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(headerTint)
                .frame(width: DS.Size.iconBadge, height: DS.Size.iconBadge)
                .background(headerTint.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(headerTitle).font(DS.Typography.headline).lineLimit(1).truncationMode(.middle)
                if let sub = headerSubtitle {
                    Text(sub).font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Spacing.xs)
            if content == .held || content == .working {
                Button { model.close() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .keyboardShortcut(.cancelAction)
                    .help(L.s("dock.close"))
                    .accessibilityLabel(Text(l: "dock.close"))
            }
        }
    }

    var actionList: some View {
        VStack(spacing: DS.Spacing.xs) {
            ForEach(model.rows) { row in
                if row.hasVariants {
                    VariantRow(model: model, row: row, interactive: content == .held)
                } else if let target = row.targets.first {
                    DockTargetButton(model: model, target: target, interactive: content == .held) {
                        RowLabel(action: row.action)
                    }
                }
            }
        }
    }

    func noticeText(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption)
            .foregroundStyle(DS.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Divider()
            DockTargetButton(model: model, target: DockTargets.openInApp, interactive: content != .ready) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "macwindow").frame(width: 20).foregroundStyle(DS.Palette.textSecondary)
                        .accessibilityHidden(true)
                    Text(l: "dock.open_in_app").font(DS.Typography.callout)
                    Spacer(minLength: 0)
                }
            }
            if content == .ready || content == .held {
                Text(l: content == .ready ? "dock.hint.release" : "dock.hint.click")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }
}

/// Icon + title of an action row.
struct RowLabel: View {
    var action: ActionID
    @Environment(\.dockTargetHot) private var isHot

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: action.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHot ? DS.Palette.onAccent : DS.Palette.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(l: action.titleKey).font(DS.Typography.callout.weight(.medium))
            Spacer(minLength: 0)
        }
    }
}

/// A row whose action has variants (formats, sizes): the title, then one chip per target.
struct VariantRow: View {
    let model: EdgeDockModel
    let row: DockRow
    var interactive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            RowLabel(action: row.action)
                .padding(.horizontal, DS.Spacing.s)
            HStack(spacing: DS.Spacing.xs) {
                ForEach(row.targets) { target in
                    DockTargetButton(model: model, target: target, interactive: interactive, compact: true) {
                        Text(target.label ?? "")
                            .font(DS.Typography.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel(Text(verbatim: "\(L.s(row.action.titleKey)) \(target.label ?? "")"))
                }
            }
            .padding(.leading, DS.Spacing.s + 20 + DS.Spacing.s)
        }
        .padding(.vertical, DS.Spacing.xxs)
    }
}

/// One drop target. While dragging, it lights up when the pointer is over it (the controller
/// hit-tests the frames reported here); once files are held, it is a regular button.
struct DockTargetButton<Label: View>: View {
    let model: EdgeDockModel
    let target: DockTarget
    var interactive: Bool
    var compact = false
    @ViewBuilder var label: () -> Label

    var isHot: Bool { model.hoveredTargetID == target.id }

    var body: some View {
        Button { model.run(target) } label: {
            label()
                .environment(\.dockTargetHot, isHot)
                .padding(.horizontal, compact ? DS.Spacing.xs : DS.Spacing.s)
                .padding(.vertical, compact ? DS.Spacing.xs + 1 : DS.Spacing.s - 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: compact ? DS.Radius.s : DS.Radius.m, style: .continuous)
                        .fill(isHot ? DS.Palette.accent : (compact ? DS.Palette.accentSoft : Color.clear))
                )
                .foregroundStyle(isHot ? DS.Palette.onAccent : DS.Palette.textPrimary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(interactive)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EdgeDockSpace.name)) } action: { frame in
            model.targetFrames[target.id] = frame
        }
        .accessibilityAddTraits(isHot ? .isSelected : [])
    }
}

/// Progress and results for the jobs started from the dock.
struct EdgeDockJobsView: View {
    let model: EdgeDockModel
    static let visibleLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ForEach(model.jobs.prefix(Self.visibleLimit)) { item in
                EdgeDockJobRow(item: item)
            }
            if model.jobs.count > Self.visibleLimit {
                Text(L.f("dock.working.more", model.jobs.count - Self.visibleLimit))
                    .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Divider()
            HStack {
                Button { model.showQueue() } label: { Text(l: "dock.show_queue") }
                    .buttonStyle(.link)
                Spacer()
                if model.allJobsFinished, model.jobs.contains(where: { $0.outcome?.outputURL != nil }) {
                    Text(l: "dock.hint.drag_out").font(DS.Typography.caption).foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .font(DS.Typography.caption)
        }
    }
}

struct EdgeDockJobRow: View {
    let item: JobItem

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.s) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(item.outcome?.outputURL?.lastPathComponent ?? item.fileName)
                    .font(DS.Typography.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .completed:
                    if let out = item.outcome {
                        if let skipped = out.skippedBecauseExists {
                            Text(L.f("result.skipped", skipped.lastPathComponent))
                                .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                        } else {
                            SizeComparisonView(before: out.inputBytes, after: out.outputBytes)
                                .font(DS.Typography.caption.monospacedDigit())
                        }
                    }
                case .failed:
                    Text(item.error.map(L.error) ?? L.s("status.failed"))
                        .font(DS.Typography.caption).foregroundStyle(DS.Palette.danger).lineLimit(2)
                case .cancelled:
                    Text(l: "status.cancelled").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                case .waiting:
                    Text(l: "status.waiting").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                default:
                    if let f = item.fraction, item.status == .processing {
                        ProgressView(value: f).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
            Spacer(minLength: DS.Spacing.xs)
            if item.status == .completed, let url = item.outcome?.outputURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help(L.s("result.reveal"))
                    .accessibilityLabel(Text(l: "result.reveal"))
                FileDragHandle(url: url)
            } else if item.status == .failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DS.Palette.danger)
                    .accessibilityLabel(Text(l: "status.failed"))
            }
        }
    }
}

/// The result's icon; drag it into Finder, Mail, a browser or a chat app.
struct FileDragHandle: View {
    let url: URL

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: DS.Size.iconBadge, height: DS.Size.iconBadge)
            .padding(DS.Spacing.xxs)
            .background(DS.Palette.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .help(L.s("result.drag"))
            .accessibilityLabel(Text(l: "result.drag"))
    }
}
