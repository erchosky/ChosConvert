import AppKit
import ChosConvertKit
import SwiftUI

struct QueueView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.queue.items.isEmpty {
                ContentUnavailableView {
                    Label { Text(l: "queue.empty.title") } icon: { Image(systemName: "tray") }
                } description: {
                    Text(l: "queue.empty.subtitle")
                }
            } else {
                List {
                    ForEach(model.queue.items.reversed()) { item in
                        JobRow(item: item, queue: model.queue)
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(Text(l: "nav.queue"))
        .toolbar {
            ToolbarItemGroup {
                if model.queue.items.contains(where: { $0.status == .failed }) {
                    Button { model.queue.retryFailed() } label: {
                        Label { Text(l: "queue.retry.failed") } icon: { Image(systemName: "arrow.clockwise") }
                    }
                }
                Button { model.queue.cancelAll() } label: {
                    Label { Text(l: "queue.cancel.all") } icon: { Image(systemName: "stop.circle") }
                }
                .disabled(model.queue.activeCount + model.queue.waitingCount == 0)
                Button { model.queue.clearFinished() } label: {
                    Label { Text(l: "queue.clear") } icon: { Image(systemName: "checkmark.circle.badge.xmark") }
                }
                .disabled(!model.queue.hasFinished)
            }
        }
    }
}

struct JobRow: View {
    let item: JobItem
    let queue: JobQueue

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            statusIcon.frame(width: DS.Size.iconBadge, height: DS.Size.iconBadge)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.s) {
                    Text(item.fileName).font(DS.Typography.body).lineLimit(1).truncationMode(.middle)
                    if let out = item.outcome {
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(DS.Palette.textTertiary)
                            .accessibilityHidden(true)
                        FormatBadge(text: out.outputFormat.displayName)
                    }
                    Spacer()
                    trailingButtons
                }
                content
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder var statusIcon: some View {
        switch item.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.success).font(.title3)
                .accessibilityLabel(Text(l: "status.completed"))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DS.Palette.danger).font(.title3)
                .accessibilityLabel(Text(l: "status.failed"))
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(DS.Palette.textTertiary).font(.title3)
                .accessibilityLabel(Text(l: "status.cancelled"))
        case .waiting:
            Image(systemName: "clock").foregroundStyle(DS.Palette.textSecondary).font(.title3)
                .accessibilityLabel(Text(l: "status.waiting"))
        default:
            ProgressView().controlSize(.small).accessibilityLabel(Text(l: "status.processing"))
        }
    }

    @ViewBuilder var content: some View {
        switch item.status {
        case .waiting:
            Text(l: "status.waiting").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
        case .inspecting, .preparing, .processing, .finalizing:
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                if let f = item.fraction, item.status == .processing {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(progressLine).font(DS.Typography.caption.monospacedDigit()).foregroundStyle(DS.Palette.textSecondary)
            }
        case .completed:
            if let out = item.outcome {
                if let skipped = out.skippedBecauseExists {
                    Text(L.f("result.skipped", skipped.lastPathComponent)).font(DS.Typography.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        SizeComparisonView(before: out.inputBytes, after: out.outputBytes)
                        HStack(spacing: DS.Spacing.s) {
                            if let url = out.outputURL {
                                Text(url.lastPathComponent).font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if let e = item.elapsed {
                                Text("· \(Fmt.eta(e))").font(DS.Typography.caption).foregroundStyle(DS.Palette.textTertiary)
                            }
                            if out.fallbackReason != nil {
                                Text(l: "result.fallback").font(DS.Typography.caption).foregroundStyle(DS.Palette.warning)
                                    .help(L.s("result.fallback.help"))
                            }
                        }
                    }
                }
            }
        case .failed:
            if let error = item.error {
                ErrorPanel(error: error) { recovery in
                    switch recovery {
                    case "try_software_encoding": queue.retryWithSoftwareEncoding(item)
                    default: queue.retry(item)
                    }
                }
            }
        case .cancelled:
            Text(l: "status.cancelled").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
        }
    }

    var progressLine: String {
        var parts: [String] = [L.s("status.\(item.status.rawValue)")]
        if let f = item.fraction, item.status == .processing { parts.append(Fmt.percent(f)) }
        if let d = item.detail, d.passes > 1 { parts.append(L.f("progress.pass", Int(d.pass), Int(d.passes))) }
        if let d = item.detail, d.attempt > 1 { parts.append(L.f("progress.attempt", Int(d.attempt))) }
        if let s = item.speed, s > 0 { parts.append(String(format: "%.1f×", s)) }
        if let eta = item.eta { parts.append(L.f("progress.eta", Fmt.eta(eta))) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder var trailingButtons: some View {
        if item.status == .completed, let url = item.outcome?.outputURL {
            HStack(spacing: DS.Spacing.xs) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help(L.s("result.reveal")).accessibilityLabel(Text(l: "result.reveal"))
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help(L.s("result.open")).accessibilityLabel(Text(l: "result.open"))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                } label: { Image(systemName: "doc.on.doc") }
                    .help(L.s("result.copy")).accessibilityLabel(Text(l: "result.copy"))
                // Drag the result straight into Finder, Mail, a browser or a chat app.
                Image(systemName: "hand.draw")
                    .foregroundStyle(DS.Palette.accent)
                    .padding(DS.Spacing.xs)
                    .background(DS.Palette.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.s))
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    .help(L.s("result.drag"))
                    .accessibilityLabel(Text(l: "result.drag"))
            }
            .buttonStyle(.borderless)
        } else if !item.status.isTerminal {
            Button { queue.cancel(item) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help(L.s("common.cancel")).accessibilityLabel(Text(l: "common.cancel"))
        } else if item.status == .failed || item.status == .cancelled {
            Button { queue.retry(item) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L.s("queue.retry")).accessibilityLabel(Text(l: "queue.retry"))
        }
    }
}
