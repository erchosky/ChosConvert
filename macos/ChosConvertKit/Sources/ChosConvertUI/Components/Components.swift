import AppKit
import ChosConvertKit
import SwiftUI

/// Large drop target shown when nothing is loaded.
struct DropZoneView: View {
    var isTargeted: Bool
    var onChoose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? DS.Palette.accent : DS.Palette.textSecondary)
                .symbolEffect(.bounce, value: isTargeted)
                .accessibilityHidden(true)
            VStack(spacing: DS.Spacing.xs) {
                Text(l: "home.drop.title").font(DS.Typography.title)
                Text(l: "home.drop.subtitle")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: onChoose) { Text(l: "home.drop.choose") }
                .controlSize(.large)
            Label { Text(l: "home.drop.privacy") } icon: { Image(systemName: "lock.shield") }
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(DS.Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                .fill(isTargeted ? DS.Palette.accentSoft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                .strokeBorder(isTargeted ? DS.Palette.accent : DS.Palette.border,
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [7, 5]))
        )
        .animation(DS.Motion.animation(reduceMotion: reduceMotion), value: isTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(l: "home.drop.a11y"))
    }
}

/// Thumbnail or family icon.
struct FileIcon: View {
    var thumbnail: NSImage?
    var family: FileFamily

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: family.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(DS.Palette.family(family.tint))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Palette.family(family.tint).opacity(0.12))
            }
        }
        .frame(width: DS.Size.thumbnail, height: DS.Size.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Inline badge such as "MP4".
struct FormatBadge: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, DS.Spacing.s - 2)
            .padding(.vertical, DS.Spacing.xxs)
            .background(DS.Palette.accentSoft, in: Capsule())
            .foregroundStyle(DS.Palette.accent)
    }
}

/// "487 MB → 21 MB  −95.7%"
struct SizeComparisonView: View {
    var before: UInt64
    var after: UInt64

    var body: some View {
        let change = before > 0 ? (Double(after) - Double(before)) / Double(before) : 0
        HStack(spacing: DS.Spacing.s) {
            Text(Fmt.bytes(before)).foregroundStyle(DS.Palette.textSecondary)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            Text(Fmt.bytes(after)).fontWeight(.semibold)
            Text(Fmt.percent(change, signed: true))
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, DS.Spacing.xs + 2)
                .padding(.vertical, 1)
                .background((change <= 0 ? DS.Palette.success : DS.Palette.warning).opacity(0.15), in: Capsule())
                .foregroundStyle(change <= 0 ? DS.Palette.success : DS.Palette.warning)
        }
        .font(DS.Typography.numeric)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L.f("result.size.a11y", Fmt.bytes(before), Fmt.bytes(after), Fmt.percent(change, signed: true)))
    }
}

/// Human error with recovery suggestions and expandable technical details.
struct ErrorPanel: View {
    var error: ChosError
    var onRecovery: ((String) -> Void)?
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Label { Text(L.error(error)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
            }
            .font(DS.Typography.callout)
            HStack(spacing: DS.Spacing.s) {
                if let onRecovery {
                    ForEach(error.recovery ?? [], id: \.self) { r in
                        if Self.actionable.contains(r) {
                            Button(L.recovery(r)) { onRecovery(r) }.controlSize(.small)
                        }
                    }
                }
                if error.details != nil {
                    Button { showDetails.toggle() } label: {
                        Text(l: showDetails ? "error.details.hide" : "error.details.show")
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            if showDetails, let details = error.details {
                ScrollView {
                    Text("\(error.code) · \(error.category)\n\(details)")
                        .font(DS.Typography.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(DS.Spacing.s)
                .background(DS.Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.s))
            }
        }
    }

    /// Recovery actions the queue can perform directly.
    static let actionable: Set<String> = ["retry", "try_software_encoding", "grant_folder_access"]
}

/// Chip-style single choice for formats.
struct ChoiceChips<T: Hashable & Identifiable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String

    var body: some View {
        FlowLayout(spacing: DS.Spacing.s) {
            ForEach(options) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(DS.Typography.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, DS.Spacing.m)
                        .padding(.vertical, DS.Spacing.xs + 1)
                        .background(selected ? DS.Palette.accent : DS.Palette.surfaceRaised, in: Capsule())
                        .foregroundStyle(selected ? Color.white : DS.Palette.textPrimary)
                        .overlay(Capsule().strokeBorder(selected ? Color.clear : DS.Palette.border))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
