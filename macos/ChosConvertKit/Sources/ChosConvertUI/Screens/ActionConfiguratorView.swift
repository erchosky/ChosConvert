import ChosConvertKit
import SwiftUI

/// Sheet that turns a smart action into an intent: simple controls first, advanced on demand,
/// with a live plan preview (steps, notes, size estimate) computed by the core planner.
struct ActionConfiguratorView: View {
    @Bindable var model: AppModel
    let request: ActionRequest

    @State private var level: QualityLevel = .balanced
    @State private var format: FileFormat = .mp4
    @State private var keepOriginalAudio = true
    @State private var targetMB: Double = 25
    @State private var maxDimension: UInt32 = 1920
    @State private var gifStart: Double = 0
    @State private var gifDuration: Double = 5
    @State private var gifWidth: UInt32 = 480
    @State private var options = AdvancedOptions()
    @State private var showAdvanced = false
    @Environment(\.dismiss) private var dismiss

    var files: [MediaInfo] { model.readyFiles }
    var first: MediaInfo? { files.first }
    var family: FileFamily { first?.family ?? .unknown }

    var intent: Intent {
        switch request.action.id {
        case .makeSmaller: .makeSmaller(level)
        case .targetSize: .targetSize(bytes: UInt64(max(0.1, targetMB) * 1_000_000))
        case .convert: .convert(format)
        case .extractAudio: .extractAudio(keepOriginalAudio ? nil : format)
        case .createGif: .createGif(startS: gifStart, durationS: gifDuration, width: gifWidth, fps: 12)
        case .resize: .resize(maxDimension: maxDimension)
        case .webOptimize: .webOptimize
        case .removeMetadata: .removeMetadata(.all)
        case .removeLocation: .removeMetadata(.location)
        }
    }

    var plan: Result<ConversionPlan, ChosError>? {
        guard let first else { return nil }
        return model.plan(intent, options: options, for: first)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    simpleControls
                    if showsAdvanced {
                        DisclosureGroup(isExpanded: $showAdvanced) {
                            AdvancedOptionsView(family: family, action: request.action.id, options: $options,
                                                capabilities: model.capabilities)
                                .padding(.top, DS.Spacing.s)
                        } label: { Text(l: "config.advanced").font(DS.Typography.headline) }
                    }
                    planPreview
                }
                .padding(DS.Spacing.xl)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 560)
        .onAppear(perform: setDefaults)
    }

    var header: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: request.action.id.symbol).font(.title2).foregroundStyle(DS.Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(l: request.action.id.titleKey).font(DS.Typography.title)
                Text(files.count == 1 ? (first?.fileName ?? "") : L.f("home.selection.many", files.count))
                    .font(DS.Typography.callout).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(DS.Spacing.xl)
    }

    var showsAdvanced: Bool {
        ![.removeMetadata, .removeLocation].contains(request.action.id)
    }

    @ViewBuilder var simpleControls: some View {
        switch request.action.id {
        case .makeSmaller:
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text(l: "config.quality").font(DS.Typography.headline)
                Picker(selection: $level) {
                    ForEach(QualityLevel.allCases) { Text(l: "quality.\($0.rawValue)").tag($0) }
                } label: { Text(l: "config.quality") }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(l: "quality.\(level.rawValue).hint").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        case .targetSize:
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text(l: "config.target").font(DS.Typography.headline)
                HStack {
                    TextField(value: $targetMB, format: .number.precision(.fractionLength(0...1))) { Text(l: "config.target") }
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                    Text("MB")
                    Spacer()
                    ForEach([8.0, 10, 25, 50, 100], id: \.self) { mb in
                        Button("\(Int(mb)) MB") { targetMB = mb }.controlSize(.small)
                    }
                }
                Text(l: "config.target.hint").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        case .convert:
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text(l: "config.format").font(DS.Typography.headline)
                ChoiceChips(options: request.action.formats ?? [], selection: $format) { $0.displayName }
            }
        case .extractAudio:
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Toggle(isOn: $keepOriginalAudio) { Text(l: "config.audio.original") }
                if !keepOriginalAudio {
                    ChoiceChips(options: request.action.formats ?? [], selection: $format) { $0.displayName }
                }
            }
        case .createGif:
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
                GridRow {
                    Text(l: "config.gif.start")
                    Stepper(value: $gifStart, in: 0...max(0, (first?.durationS ?? 0) - 0.5), step: 0.5) {
                        Text(Fmt.duration(gifStart)).font(DS.Typography.numeric)
                    }
                }
                GridRow {
                    Text(l: "config.gif.duration")
                    Stepper(value: $gifDuration, in: 1...30, step: 1) { Text("\(Int(gifDuration)) s").font(DS.Typography.numeric) }
                }
                GridRow {
                    Text(l: "config.gif.width")
                    Picker(selection: $gifWidth) {
                        ForEach([320, 480, 640, 800] as [UInt32], id: \.self) { Text("\($0) px").tag($0) }
                    } label: { EmptyView() }.labelsHidden().frame(width: 120)
                }
            }
        case .resize:
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text(l: "config.resize").font(DS.Typography.headline)
                Picker(selection: $maxDimension) {
                    ForEach(resizeOptions, id: \.self) { Text("\($0) px").tag($0) }
                } label: { EmptyView() }
                .pickerStyle(.segmented).labelsHidden()
                Text(l: family == .video ? "config.resize.video.hint" : "config.resize.hint")
                    .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        case .webOptimize:
            Text(l: "config.web.hint").font(DS.Typography.callout).foregroundStyle(DS.Palette.textSecondary)
        case .removeMetadata, .removeLocation:
            MetadataPreview(files: files, locationOnly: request.action.id == .removeLocation)
        }
    }

    var resizeOptions: [UInt32] {
        family == .video ? [480, 720, 1080, 1440] : [640, 1280, 1920, 2560, 3840]
    }

    @ViewBuilder var planPreview: some View {
        if let plan {
            switch plan {
            case .success(let p):
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Text(l: "config.plan").font(DS.Typography.headline)
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.l) {
                        if let first {
                            VStack(alignment: .leading) {
                                Text(l: "config.plan.original").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                                Text(Fmt.bytes(first.sizeBytes)).font(DS.Typography.numeric)
                            }
                        }
                        if let est = p.estimate {
                            VStack(alignment: .leading) {
                                Text(l: "config.plan.estimate").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                                Text(Fmt.approxBytes(est.bytes)).font(DS.Typography.numeric.weight(.semibold))
                                    .help(L.f("config.plan.range", Fmt.bytes(est.lowBytes), Fmt.bytes(est.highBytes)))
                            }
                        }
                        VStack(alignment: .leading) {
                            Text(l: "config.plan.output").font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                            Text(p.outputFormat.displayName).font(DS.Typography.numeric)
                        }
                        Spacer()
                    }
                    Text(p.steps.filter { !["inspect", "verify", "finalize"].contains($0) }.map(L.step).joined(separator: " → "))
                        .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                    ForEach(p.notes ?? [], id: \.self) { note in
                        if let text = L.note(note) {
                            Label { Text(text) } icon: { Image(systemName: "info.circle") }
                                .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    if p.estimate != nil {
                        Text(l: "config.plan.estimate.disclaimer").font(.caption2).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                .card()
            case .failure(let e):
                ErrorPanel(error: e).card()
            }
        }
    }

    var footer: some View {
        HStack {
            Label {
                Text(model.settings.outputMode == .sameFolder ? L.s("config.output.same") :
                        L.f("config.output.custom", URL(fileURLWithPath: model.settings.customOutputFolder ?? "").lastPathComponent))
            } icon: { Image(systemName: "folder") }
            .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
            Spacer()
            Button(role: .cancel) { dismiss() } label: { Text(l: "common.cancel") }
                .keyboardShortcut(.cancelAction)
            Button {
                model.start(intent, options: options, files: files)
            } label: {
                Text(files.count > 1 ? L.f("config.start.many", files.count) : L.s("config.start"))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(planIsFailure || files.isEmpty)
        }
        .padding(DS.Spacing.l)
    }

    var planIsFailure: Bool {
        if case .failure = plan { return true }
        return false
    }

    func setDefaults() {
        if let f = request.action.formats?.first { format = f }
        if request.action.id == .convert, family == .image, let jpeg = request.action.formats?.first(where: { $0 == .jpeg }) {
            format = jpeg
        }
        if request.action.id == .convert, family == .video, request.action.formats?.contains(.mp4) == true { format = .mp4 }
        if request.action.id == .resize { maxDimension = family == .video ? 1080 : 1920 }
        if let d = first?.durationS, d > 0 { gifDuration = min(5, d) }
        if let preferred = request.preferredFormat, request.action.formats?.contains(preferred) == true {
            format = preferred
            if request.action.id == .extractAudio { keepOriginalAudio = false }
        }
    }
}

/// Shows exactly which personal metadata will be removed before the user confirms.
struct MetadataPreview: View {
    var files: [MediaInfo]
    var locationOnly: Bool

    var entries: [MetadataEntry] {
        guard let first = files.first else { return [] }
        let all = first.metadata.filter { $0.sensitive }
        return locationOnly ? all.filter { $0.key.localizedCaseInsensitiveContains("gps") || $0.key.localizedCaseInsensitiveContains("location") } : all
    }

    var hintKey: String {
        guard locationOnly else { return "privacy.all.hint" }
        return files.first?.family == .image ? "privacy.location.hint" : "privacy.location.hint.media"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(l: locationOnly ? "privacy.location.title" : "privacy.all.title").font(DS.Typography.headline)
            if entries.isEmpty {
                Text(l: "privacy.none").font(DS.Typography.callout).foregroundStyle(DS.Palette.textSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.xs) {
                    ForEach(entries.prefix(12), id: \.self) { e in
                        GridRow {
                            Image(systemName: "minus.circle.fill").foregroundStyle(DS.Palette.danger).accessibilityHidden(true)
                            Text(e.key).font(DS.Typography.caption.weight(.medium))
                            Text(e.value).font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                        }
                    }
                }
            }
            Text(l: hintKey)
                .font(DS.Typography.caption).foregroundStyle(DS.Palette.textSecondary)
            if files.count > 1 {
                Text(L.f("privacy.batch", files.count)).font(DS.Typography.caption).foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .card()
    }
}

struct AdvancedOptionsView: View {
    var family: FileFamily
    var action: ActionID
    @Binding var options: AdvancedOptions
    var capabilities: Capabilities?

    var body: some View {
        Form {
            switch family {
            case .video:
                Picker(selection: $options.videoCodec) {
                    Text(l: "advanced.auto").tag(VideoCodecChoice?.none)
                    ForEach(availableCodecs) { Text($0.displayName).tag(VideoCodecChoice?.some($0)) }
                } label: { Text(l: "advanced.video.codec") }
                Picker(selection: $options.encoder) {
                    Text(l: "advanced.encoder.auto").tag(EncoderChoice?.none)
                    Text(l: "advanced.encoder.hardware").tag(EncoderChoice?.some(.hardware))
                    Text(l: "advanced.encoder.software").tag(EncoderChoice?.some(.software))
                } label: { Text(l: "advanced.encoder") }
                if action != .targetSize {
                    optionalNumber("advanced.crf", value: $options.crf, range: 0...63)
                    optionalNumber("advanced.video.kbps", value: $options.videoKbps, range: 100...200_000)
                }
                Picker(selection: $options.maxShortSide) {
                    Text(l: "advanced.original").tag(UInt32?.none)
                    ForEach([2160, 1440, 1080, 720, 480] as [UInt32], id: \.self) { Text("\($0)p").tag(UInt32?.some($0)) }
                } label: { Text(l: "advanced.resolution") }
                Picker(selection: $options.fps) {
                    Text(l: "advanced.original").tag(Double?.none)
                    ForEach([60.0, 30, 25, 24], id: \.self) { Text("\(Int($0)) fps").tag(Double?.some($0)) }
                } label: { Text(l: "advanced.fps") }
                Toggle(isOn: bool(\.removeAudio)) { Text(l: "advanced.remove.audio") }
                optionalNumber("advanced.audio.kbps", value: $options.audioKbps, range: 32...512)
                Toggle(isOn: bool(\.stripMetadata)) { Text(l: "advanced.strip.metadata") }
            case .audio:
                optionalNumber("advanced.audio.kbps", value: $options.audioKbps, range: 32...512)
                Picker(selection: $options.sampleRate) {
                    Text(l: "advanced.original").tag(UInt32?.none)
                    ForEach([48000, 44100, 32000, 22050] as [UInt32], id: \.self) { Text("\($0) Hz").tag(UInt32?.some($0)) }
                } label: { Text(l: "advanced.sample.rate") }
                Picker(selection: $options.audioChannels) {
                    Text(l: "advanced.original").tag(UInt32?.none)
                    Text(l: "audio.mono").tag(UInt32?.some(1))
                    Text(l: "audio.stereo").tag(UInt32?.some(2))
                } label: { Text(l: "advanced.channels") }
                Toggle(isOn: bool(\.stripMetadata)) { Text(l: "advanced.strip.metadata") }
            case .image:
                LabeledContent {
                    HStack {
                        Slider(value: Binding(get: { options.imageQuality ?? 0.8 }, set: { options.imageQuality = $0 }), in: 0.3...1)
                        Text(options.imageQuality.map { "\(Int($0 * 100))" } ?? L.s("advanced.auto"))
                            .font(DS.Typography.numeric).frame(width: 44, alignment: .trailing)
                    }
                } label: { Text(l: "advanced.image.quality") }
                optionalNumber("advanced.image.max", value: $options.imageMaxDimension, range: 16...16_000)
                Toggle(isOn: bool(\.imageLossless)) { Text(l: "advanced.image.lossless") }
                Toggle(isOn: bool(\.convertToSrgb)) { Text(l: "advanced.image.srgb") }
                Toggle(isOn: bool(\.stripMetadata)) { Text(l: "advanced.strip.metadata") }
            default:
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    var availableCodecs: [VideoCodecChoice] {
        guard let ff = capabilities?.ffmpeg else { return [.h264, .hevc] }
        return VideoCodecChoice.allCases.filter { c in ff.encoders.contains { $0.codec == c.rawValue && $0.kind == "video" } }
    }

    func bool(_ kp: WritableKeyPath<AdvancedOptions, Bool?>) -> Binding<Bool> {
        Binding(get: { options[keyPath: kp] ?? false }, set: { options[keyPath: kp] = $0 ? true : nil })
    }

    @ViewBuilder
    func optionalNumber(_ key: String, value: Binding<UInt32?>, range: ClosedRange<UInt32>) -> some View {
        LabeledContent {
            TextField(L.s("advanced.auto"), value: Binding(
                get: { value.wrappedValue.map(Int.init) },
                set: { value.wrappedValue = $0.map { UInt32(clamping: max(Int(range.lowerBound), min(Int(range.upperBound), $0))) } }
            ), format: .number)
            .frame(width: 90)
            .multilineTextAlignment(.trailing)
        } label: { Text(l: key) }
    }
}
