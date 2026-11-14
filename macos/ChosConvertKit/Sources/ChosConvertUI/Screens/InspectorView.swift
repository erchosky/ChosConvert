import ChosConvertKit
import SwiftUI

/// File inspector: what ChosConvert detected about the selected file.
struct InspectorView: View {
    let file: DroppedFile?

    var body: some View {
        ScrollView {
            if let file {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    HStack(spacing: DS.Spacing.m) {
                        FileIcon(thumbnail: file.thumbnail, family: file.info?.family ?? .unknown)
                        Text(file.url.lastPathComponent).font(DS.Typography.headline).lineLimit(2)
                    }
                    switch file.state {
                    case .inspecting:
                        ProgressView().frame(maxWidth: .infinity)
                    case .failed(let e):
                        ErrorPanel(error: e)
                    case .ready(let info):
                        sections(info)
                    }
                }
                .padding(DS.Spacing.l)
            } else {
                Text(l: "inspector.empty").foregroundStyle(DS.Palette.textSecondary).padding()
            }
        }
        .frame(minWidth: 260)
    }

    @ViewBuilder func sections(_ m: MediaInfo) -> some View {
        Section("inspector.general") {
            Row("inspector.format", m.detection.format.displayName)
            Row("inspector.mime", m.detection.mime)
            if m.detection.isExtensionMismatch {
                Row("inspector.extension", L.f("inspector.extension.mismatch", m.detection.extension ?? "—"))
            }
            Row("inspector.size", Fmt.bytes(m.sizeBytes))
            if let d = m.durationS { Row("inspector.duration", Fmt.duration(d)) }
            if let b = m.bitRate { Row("inspector.bitrate", "\(b / 1000) kb/s") }
            if let c = m.container { Row("inspector.container", c) }
        }
        if let img = m.image {
            Section("inspector.image") {
                Row("inspector.dimensions", "\(img.width)×\(img.height)")
                if let o = img.orientation, o != 1 { Row("inspector.orientation", "\(o)") }
                if let d = img.bitDepth { Row("inspector.bitdepth", "\(d)") }
                Row("inspector.alpha", L.s(img.hasAlpha ? "common.yes" : "common.no"))
                if let cm = img.colorModel { Row("inspector.colormodel", cm) }
                if let p = img.colorProfile { Row("inspector.profile", p) }
                if let dpi = img.dpi { Row("inspector.dpi", "\(Int(dpi))") }
                if img.frameCount > 1 { Row("inspector.frames", "\(img.frameCount)") }
            }
        }
        ForEach(m.video, id: \.index) { v in
            Section("inspector.video") {
                Row("inspector.codec", Fmt.codec(v.codec) + (v.profile.map { " (\($0))" } ?? ""))
                Row("inspector.resolution", "\(v.width)×\(v.height)")
                if v.rotation != 0 { Row("inspector.rotation", "\(v.rotation)°") }
                if let f = v.fps { Row("inspector.fps", String(format: "%.3g", f)) }
                if let b = v.bitRate { Row("inspector.bitrate", "\(b / 1000) kb/s") }
                if let p = v.pixFmt { Row("inspector.pixfmt", p) }
                Row("inspector.dynamicrange", v.hdr ? "HDR" : "SDR")
            }
        }
        ForEach(m.audio, id: \.index) { a in
            Section("inspector.audio") {
                Row("inspector.codec", Fmt.codec(a.codec))
                if let sr = a.sampleRate { Row("inspector.samplerate", "\(sr) Hz") }
                if let ch = a.channels { Row("inspector.channels", Fmt.channels(ch)) }
                if let b = a.bitRate { Row("inspector.bitrate", "\(b / 1000) kb/s") }
                if let l = a.language, l != "und" { Row("inspector.language", l) }
            }
        }
        if !m.subtitles.isEmpty {
            Section("inspector.subtitles") {
                ForEach(m.subtitles, id: \.index) { s in Row("inspector.codec", s.codec + (s.language.map { " · \($0)" } ?? "")) }
            }
        }
        if let pdf = m.pdf {
            Section("inspector.pdf") {
                Row("inspector.pages", "\(pdf.pageCount)")
                if let v = pdf.version { Row("inspector.pdfversion", v) }
                Row("inspector.encrypted", L.s(pdf.encrypted ? "common.yes" : "common.no"))
            }
        }
        if !m.metadata.isEmpty {
            Section("inspector.metadata") {
                ForEach(m.metadata.prefix(40), id: \.self) { e in
                    Row(e.key, e.value, localizedKey: false, highlight: e.sensitive)
                }
            }
        }
    }

    struct Section<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content
        init(_ title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }
        var body: some View {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(l: title).font(DS.Typography.caption.weight(.semibold)).foregroundStyle(DS.Palette.textSecondary)
                    .textCase(.uppercase)
                content
            }
        }
    }

    struct Row: View {
        let key: String
        let value: String
        var localizedKey = true
        var highlight = false
        init(_ key: String, _ value: String, localizedKey: Bool = true, highlight: Bool = false) {
            self.key = key; self.value = value; self.localizedKey = localizedKey; self.highlight = highlight
        }
        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                Group { localizedKey ? Text(l: key) : Text(key) }
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: 104, alignment: .leading)
                Text(value).textSelection(.enabled).lineLimit(3)
                if highlight {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(DS.Palette.warning)
                        .help(L.s("inspector.sensitive"))
                        .accessibilityLabel(Text(l: "inspector.sensitive"))
                }
            }
            .font(DS.Typography.caption)
        }
    }
}
