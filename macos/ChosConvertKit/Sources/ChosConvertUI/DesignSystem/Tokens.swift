import ChosConvertKit
import AppKit
import SwiftUI

/// ChosConvert design tokens. Views use these instead of literal values.
public enum DS {
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    public enum Radius {
        public static let s: CGFloat = 6
        public static let m: CGFloat = 10
        public static let l: CGFloat = 14
        public static let xl: CGFloat = 20
    }

    public enum Motion {
        public static let fast: Double = 0.12
        public static let standard: Double = 0.2
        public static let slow: Double = 0.32

        /// Animation that collapses to none when Reduce Motion is on.
        public static func animation(_ duration: Double = standard, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .smooth(duration: duration)
        }
    }

    public enum Size {
        public static let actionTileMinWidth: CGFloat = 148
        public static let actionTileHeight: CGFloat = 84
        public static let thumbnail: CGFloat = 44
        public static let iconBadge: CGFloat = 28
    }

    /// Semantic colors. Each adapts to light/dark and Increase Contrast via AppKit dynamic colors.
    public enum Palette {
        static func dynamic(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
            })
        }

        /// Brand accent: a calm indigo, distinct from the system blue and from orange competitors.
        public static let accent = dynamic(light: NSColor(srgbRed: 0.31, green: 0.33, blue: 0.86, alpha: 1),
                                           dark: NSColor(srgbRed: 0.56, green: 0.60, blue: 1.00, alpha: 1))
        public static let accentSoft = dynamic(light: NSColor(srgbRed: 0.31, green: 0.33, blue: 0.86, alpha: 0.10),
                                               dark: NSColor(srgbRed: 0.56, green: 0.60, blue: 1.00, alpha: 0.16))
        /// Text and icons on an `accent` fill (the dark-mode accent is light, so text turns dark).
        public static let onAccent = dynamic(light: .white, dark: NSColor(white: 0.08, alpha: 1))
        public static let surface = Color(nsColor: .windowBackgroundColor)
        public static let surfaceRaised = Color(nsColor: .controlBackgroundColor)
        public static let surfaceSunken = Color(nsColor: .underPageBackgroundColor)
        public static let border = Color(nsColor: .separatorColor)
        public static let textPrimary = Color(nsColor: .labelColor)
        public static let textSecondary = Color(nsColor: .secondaryLabelColor)
        public static let textTertiary = Color(nsColor: .tertiaryLabelColor)
        public static let success = Color(nsColor: .systemGreen)
        public static let warning = Color(nsColor: .systemOrange)
        public static let danger = Color(nsColor: .systemRed)
        public static let focus = Color(nsColor: .keyboardFocusIndicatorColor)

        public static func family(_ f: FileFamilyTint) -> Color {
            switch f {
            case .image: Color(nsColor: .systemTeal)
            case .video: Color(nsColor: .systemIndigo)
            case .audio: Color(nsColor: .systemPink)
            case .document: Color(nsColor: .systemBrown)
            case .other: Color(nsColor: .systemGray)
            }
        }
    }

    public enum FileFamilyTint { case image, video, audio, document, other }

    public enum Typography {
        public static let display = Font.system(.largeTitle, design: .rounded, weight: .semibold)
        public static let title = Font.title2.weight(.semibold)
        public static let headline = Font.headline
        public static let body = Font.body
        public static let callout = Font.callout
        public static let caption = Font.caption
        public static let mono = Font.system(.caption, design: .monospaced)
        public static let numeric = Font.body.monospacedDigit()
    }
}

/// Raised card used for grouped content.
struct CardModifier: ViewModifier {
    var padding: CGFloat = DS.Spacing.l
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(DS.Palette.border.opacity(0.6)))
    }
}

extension View {
    func card(padding: CGFloat = DS.Spacing.l) -> some View { modifier(CardModifier(padding: padding)) }
}

/// Tile button for intent actions: hover, pressed, focus and disabled states.
struct ActionTileStyle: ButtonStyle {
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: DS.Size.actionTileHeight, alignment: .topLeading)
            .padding(DS.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .fill(hovering || configuration.isPressed ? DS.Palette.accentSoft : DS.Palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .strokeBorder(hovering ? DS.Palette.accent.opacity(0.6) : DS.Palette.border.opacity(0.7),
                                  lineWidth: hovering ? 1.5 : 1)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            .onHover { hovering = $0 && isEnabled }
            .animation(DS.Motion.animation(DS.Motion.fast, reduceMotion: reduceMotion), value: hovering)
            .animation(DS.Motion.animation(DS.Motion.fast, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension FileFamily {
    var tint: DS.FileFamilyTint {
        switch self {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .pdf, .document: .document
        default: .other
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .archive: "archivebox"
        default: "doc"
        }
    }
}
