import Foundation

// Swift mirrors of the core's JSON models (see core/chosconvert-core). Keys are converted
// between camelCase and snake_case by `CoreJSON`; enum raw values match the serde names.

public enum FileFamily: String, Codable, Sendable, Hashable {
    case image, video, audio, pdf, document, archive, executable, unknown
}

public enum FileFormat: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case jpeg, png, gif, webp, avif, heic, tiff, bmp, svg
    case mp4, mov, mkv, webm, avi
    case m4a, mp3, wav, aiff, flac, ogg, opus, caf, aac
    case pdf, txt, rtf, markdown, html, docx, xlsx, pptx, odt, ods, odp, epub
    case zip, executable, unknown

    public var id: String { rawValue }

    /// Short user-facing label such as "JPEG" or "MP4".
    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .markdown: "Markdown"
        case .executable: "Executable"
        case .unknown: "Unknown"
        default: rawValue.uppercased()
        }
    }

    public var family: FileFamily {
        switch self {
        case .jpeg, .png, .gif, .webp, .avif, .heic, .tiff, .bmp, .svg: .image
        case .mp4, .mov, .mkv, .webm, .avi: .video
        case .m4a, .mp3, .wav, .aiff, .flac, .ogg, .opus, .caf, .aac: .audio
        case .pdf: .pdf
        case .txt, .rtf, .markdown, .html, .docx, .xlsx, .pptx, .odt, .ods, .odp, .epub: .document
        case .zip: .archive
        case .executable: .executable
        case .unknown: .unknown
        }
    }
}

public struct Detection: Codable, Sendable, Hashable {
    public var format: FileFormat
    public var family: FileFamily
    public var mime: String
    public var `extension`: String?
    public var extensionMatches: Bool
    public var confidence: String
    public var sizeBytes: UInt64
    public var warnings: [String]?

    public var isExtensionMismatch: Bool { warnings?.contains("extension_mismatch") ?? false }
}

public struct VideoStream: Codable, Sendable, Hashable {
    public var index: UInt32
    public var codec: String
    public var profile: String?
    public var width: UInt32
    public var height: UInt32
    public var fps: Double?
    public var bitRate: UInt64?
    public var pixFmt: String?
    public var bitDepth: UInt32?
    public var colorTransfer: String?
    public var colorPrimaries: String?
    public var hdr: Bool
    public var rotation: Int32

    public init(index: UInt32, codec: String, profile: String? = nil, width: UInt32, height: UInt32,
                fps: Double? = nil, bitRate: UInt64? = nil, pixFmt: String? = nil, bitDepth: UInt32? = nil,
                colorTransfer: String? = nil, colorPrimaries: String? = nil, hdr: Bool = false, rotation: Int32 = 0) {
        self.index = index; self.codec = codec; self.profile = profile; self.width = width; self.height = height
        self.fps = fps; self.bitRate = bitRate; self.pixFmt = pixFmt; self.bitDepth = bitDepth
        self.colorTransfer = colorTransfer; self.colorPrimaries = colorPrimaries; self.hdr = hdr; self.rotation = rotation
    }

    public var displaySize: (width: UInt32, height: UInt32) {
        abs(Int(rotation)) % 180 == 90 ? (height, width) : (width, height)
    }
}

public struct AudioStream: Codable, Sendable, Hashable {
    public var index: UInt32
    public var codec: String
    public var sampleRate: UInt32?
    public var channels: UInt32?
    public var channelLayout: String?
    public var bitRate: UInt64?
    public var bitDepth: UInt32?
    public var language: String?

    public init(index: UInt32, codec: String, sampleRate: UInt32? = nil, channels: UInt32? = nil,
                channelLayout: String? = nil, bitRate: UInt64? = nil, bitDepth: UInt32? = nil, language: String? = nil) {
        self.index = index; self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
        self.channelLayout = channelLayout; self.bitRate = bitRate; self.bitDepth = bitDepth; self.language = language
    }
}

public struct SubtitleStream: Codable, Sendable, Hashable {
    public var index: UInt32
    public var codec: String
    public var language: String?
}

public struct ImageInfo: Codable, Sendable, Hashable {
    public var width: UInt32
    public var height: UInt32
    public var bitDepth: UInt32?
    public var hasAlpha: Bool
    public var colorModel: String?
    public var colorProfile: String?
    public var dpi: Double?
    public var orientation: UInt32?
    public var frameCount: UInt32
    public var hasExif: Bool
    public var hasGps: Bool

    public init(width: UInt32, height: UInt32, bitDepth: UInt32? = nil, hasAlpha: Bool = false,
                colorModel: String? = nil, colorProfile: String? = nil, dpi: Double? = nil,
                orientation: UInt32? = nil, frameCount: UInt32 = 1, hasExif: Bool = false, hasGps: Bool = false) {
        self.width = width; self.height = height; self.bitDepth = bitDepth; self.hasAlpha = hasAlpha
        self.colorModel = colorModel; self.colorProfile = colorProfile; self.dpi = dpi
        self.orientation = orientation; self.frameCount = frameCount; self.hasExif = hasExif; self.hasGps = hasGps
    }

    public var displaySize: (width: UInt32, height: UInt32) {
        if let o = orientation, (5...8).contains(o) { return (height, width) }
        return (width, height)
    }
}

public struct PdfInfo: Codable, Sendable, Hashable {
    public var pageCount: UInt32
    public var version: String?
    public var encrypted: Bool
    public var locked: Bool

    public init(pageCount: UInt32, version: String? = nil, encrypted: Bool = false, locked: Bool = false) {
        self.pageCount = pageCount; self.version = version; self.encrypted = encrypted; self.locked = locked
    }
}

public struct MetadataEntry: Codable, Sendable, Hashable {
    public var key: String
    public var value: String
    public var sensitive: Bool

    public init(key: String, value: String, sensitive: Bool) {
        self.key = key; self.value = value; self.sensitive = sensitive
    }
}

public struct MediaInfo: Codable, Sendable, Hashable {
    public var path: String
    public var fileName: String
    public var sizeBytes: UInt64
    public var detection: Detection
    public var family: FileFamily
    public var container: String?
    public var durationS: Double?
    public var bitRate: UInt64?
    public var video: [VideoStream]
    public var audio: [AudioStream]
    public var subtitles: [SubtitleStream]
    public var chapters: UInt32
    public var image: ImageInfo?
    public var pdf: PdfInfo?
    public var metadata: [MetadataEntry]
    public var hasLocation: Bool
    public var inspector: String

    public init(path: String, fileName: String, sizeBytes: UInt64, detection: Detection, family: FileFamily,
                container: String? = nil, durationS: Double? = nil, bitRate: UInt64? = nil,
                video: [VideoStream] = [], audio: [AudioStream] = [], subtitles: [SubtitleStream] = [],
                chapters: UInt32 = 0, image: ImageInfo? = nil, pdf: PdfInfo? = nil,
                metadata: [MetadataEntry] = [], hasLocation: Bool = false, inspector: String) {
        self.path = path; self.fileName = fileName; self.sizeBytes = sizeBytes; self.detection = detection
        self.family = family; self.container = container; self.durationS = durationS; self.bitRate = bitRate
        self.video = video; self.audio = audio; self.subtitles = subtitles; self.chapters = chapters
        self.image = image; self.pdf = pdf; self.metadata = metadata; self.hasLocation = hasLocation
        self.inspector = inspector
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var primaryVideo: VideoStream? { video.first }
    public var primaryAudio: AudioStream? { audio.first }
    public var hasSensitiveMetadata: Bool {
        hasLocation || (image?.hasGps ?? false) || metadata.contains { $0.sensitive }
    }
}

// MARK: Capabilities

public enum OperatingSystem: String, Codable, Sendable { case macos, windows, linux }

public struct PlatformInfo: Codable, Sendable, Hashable {
    public var os: OperatingSystem
    public var arch: String
    public var osVersion: String
    public var cpuCount: UInt32
    public var memoryBytes: UInt64
}

public struct NativeImageCaps: Codable, Sendable, Hashable {
    public var read: [FileFormat]
    public var write: [FileFormat]
}

public struct NativeAvCaps: Codable, Sendable, Hashable {
    public var available: Bool
    public var h264Encode: Bool
    public var hevcEncode: Bool
    public var aacEncode: Bool
    public var alacEncode: Bool
}

public struct EncoderInfo: Codable, Sendable, Hashable {
    public var name: String
    public var kind: String
    public var codec: String
    public var hardware: Bool
    public var experimental: Bool
}

public struct FfmpegCaps: Codable, Sendable, Hashable {
    public var path: String
    public var ffprobePath: String?
    public var version: String
    public var license: String
    public var configuration: String
    public var encoders: [EncoderInfo]
    public var muxers: [String]

    public var hardwareEncoders: [EncoderInfo] { encoders.filter { $0.hardware && $0.kind == "video" } }
}

public struct Capabilities: Codable, Sendable, Hashable {
    public var platform: PlatformInfo
    public var nativeImage: NativeImageCaps
    public var nativeAv: NativeAvCaps
    public var coreWebp: Bool
    public var ffmpeg: FfmpegCaps?
    public var pdfNative: Bool
    public var ocrNative: Bool

    public func canWriteImage(_ f: FileFormat) -> Bool {
        nativeImage.write.contains(f) || (f == .webp && coreWebp)
    }
}

// MARK: Intents & plans

public enum QualityLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case smaller, balanced, high
    public var id: String { rawValue }
}

public enum MetadataScope: String, Codable, Sendable { case all, location }

public enum Intent: Sendable, Hashable, Codable {
    case makeSmaller(QualityLevel)
    case convert(FileFormat)
    case extractAudio(FileFormat?)
    case removeMetadata(MetadataScope)
    case resize(maxDimension: UInt32)
    case webOptimize
    case targetSize(bytes: UInt64)
    case createGif(startS: Double, durationS: Double, width: UInt32, fps: UInt32)

    private enum CodingKeys: String, CodingKey {
        case kind, level, format, scope, maxDimension, targetBytes, startS, durationS, width, fps
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .makeSmaller(let l): try c.encode("make_smaller", forKey: .kind); try c.encode(l, forKey: .level)
        case .convert(let f): try c.encode("convert", forKey: .kind); try c.encode(f, forKey: .format)
        case .extractAudio(let f): try c.encode("extract_audio", forKey: .kind); try c.encodeIfPresent(f, forKey: .format)
        case .removeMetadata(let s): try c.encode("remove_metadata", forKey: .kind); try c.encode(s, forKey: .scope)
        case .resize(let d): try c.encode("resize", forKey: .kind); try c.encode(d, forKey: .maxDimension)
        case .webOptimize: try c.encode("web_optimize", forKey: .kind)
        case .targetSize(let b): try c.encode("target_size", forKey: .kind); try c.encode(b, forKey: .targetBytes)
        case .createGif(let s, let d, let w, let f):
            try c.encode("create_gif", forKey: .kind)
            try c.encode(s, forKey: .startS); try c.encode(d, forKey: .durationS)
            try c.encode(w, forKey: .width); try c.encode(f, forKey: .fps)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "make_smaller": self = .makeSmaller(try c.decodeIfPresent(QualityLevel.self, forKey: .level) ?? .balanced)
        case "convert": self = .convert(try c.decode(FileFormat.self, forKey: .format))
        case "extract_audio": self = .extractAudio(try c.decodeIfPresent(FileFormat.self, forKey: .format))
        case "remove_metadata": self = .removeMetadata(try c.decodeIfPresent(MetadataScope.self, forKey: .scope) ?? .all)
        case "resize": self = .resize(maxDimension: try c.decode(UInt32.self, forKey: .maxDimension))
        case "web_optimize": self = .webOptimize
        case "target_size": self = .targetSize(bytes: try c.decode(UInt64.self, forKey: .targetBytes))
        case "create_gif":
            self = .createGif(startS: try c.decode(Double.self, forKey: .startS), durationS: try c.decode(Double.self, forKey: .durationS),
                              width: try c.decode(UInt32.self, forKey: .width), fps: try c.decode(UInt32.self, forKey: .fps))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown intent \(other)")
        }
    }
}

public enum VideoCodecChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case h264, hevc, av1, vp9
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        case .av1: "AV1"
        case .vp9: "VP9"
        }
    }
}

public enum EncoderChoice: Sendable, Hashable, Codable {
    case auto, hardware, software
    case specific(String)

    private enum CodingKeys: String, CodingKey { case mode, name }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto: try c.encode("auto", forKey: .mode)
        case .hardware: try c.encode("hardware", forKey: .mode)
        case .software: try c.encode("software", forKey: .mode)
        case .specific(let n): try c.encode("specific", forKey: .mode); try c.encode(n, forKey: .name)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .mode) {
        case "hardware": self = .hardware
        case "software": self = .software
        case "specific": self = .specific(try c.decode(String.self, forKey: .name))
        default: self = .auto
        }
    }
}

public struct AdvancedOptions: Codable, Sendable, Hashable {
    public var container: FileFormat?
    public var videoCodec: VideoCodecChoice?
    public var encoder: EncoderChoice?
    public var crf: UInt32?
    public var videoKbps: UInt32?
    public var twoPass: Bool?
    public var maxShortSide: UInt32?
    public var fps: Double?
    public var audioCodec: String?
    public var audioKbps: UInt32?
    public var audioChannels: UInt32?
    public var sampleRate: UInt32?
    public var removeAudio: Bool?
    public var stripMetadata: Bool?
    public var keepSubtitles: Bool?
    public var imageQuality: Double?
    public var imageMaxDimension: UInt32?
    public var imageLossless: Bool?
    public var convertToSrgb: Bool?

    public init() {}
}

public enum EngineKind: String, Codable, Sendable { case nativeImage = "native_image", nativeAv = "native_av", ffmpeg }

public struct PlanRequest: Codable, Sendable {
    public var input: MediaInfo
    public var intent: Intent
    public var options: AdvancedOptions
    public var capabilities: Capabilities
    public var engineOverride: EngineKind?

    public init(input: MediaInfo, intent: Intent, options: AdvancedOptions, capabilities: Capabilities, engineOverride: EngineKind? = nil) {
        self.input = input; self.intent = intent; self.options = options
        self.capabilities = capabilities; self.engineOverride = engineOverride
    }
}

public struct PlanNote: Codable, Sendable, Hashable {
    public var code: String
    public var args: [String]?
}

public struct SizeEstimate: Codable, Sendable, Hashable {
    public var bytes: UInt64
    public var lowBytes: UInt64
    public var highBytes: UInt64
    public var confidence: String
}

public enum ImageMetadataPolicy: String, Codable, Sendable { case keep, stripLocation = "strip_location", stripAll = "strip_all" }
public enum ImageEncoderKind: String, Codable, Sendable { case native, coreWebp = "core_webp" }

public struct ImageJob: Codable, Sendable, Hashable {
    public var outputFormat: FileFormat
    public var encoder: ImageEncoderKind
    public var quality: Double?
    public var lossless: Bool
    public var maxDimension: UInt32?
    public var metadata: ImageMetadataPolicy
    public var convertToSrgb: Bool
    public var flattenBackground: [UInt8]?
    public var metadataOnly: Bool
    public var maxPixels: UInt64

    public init(outputFormat: FileFormat, encoder: ImageEncoderKind = .native, quality: Double? = nil, lossless: Bool = false,
                maxDimension: UInt32? = nil, metadata: ImageMetadataPolicy = .keep, convertToSrgb: Bool = false,
                flattenBackground: [UInt8]? = nil, metadataOnly: Bool = false, maxPixels: UInt64 = 400_000_000) {
        self.outputFormat = outputFormat; self.encoder = encoder; self.quality = quality; self.lossless = lossless
        self.maxDimension = maxDimension; self.metadata = metadata; self.convertToSrgb = convertToSrgb
        self.flattenBackground = flattenBackground; self.metadataOnly = metadataOnly; self.maxPixels = maxPixels
    }
}

public struct NativeAvJob: Codable, Sendable, Hashable {
    public var preset: String
    public var fileType: FileFormat
    public var stripMetadata: Bool
    public var timeRange: [Double]?
}

public struct FfmpegPass: Codable, Sendable, Hashable { public var args: [String] }

public struct FfmpegJob: Codable, Sendable, Hashable {
    public var passes: [FfmpegPass]
    public var durationS: Double?
    public var videoEncoder: String?
    public var hardware: Bool
}

public struct TargetSizeBudget: Codable, Sendable, Hashable {
    public var targetBytes: UInt64
    public var overheadBytes: UInt64
    public var audioKbps: UInt32
    public var audioChannels: UInt32
    public var videoKbps: UInt32
    public var width: UInt32
    public var height: UInt32
    public var fps: Double?
    public var estimatedBytes: UInt64
    public var lowQuality: Bool
    public var attempt: UInt32
}

public struct VerifySpec: Codable, Sendable, Hashable {
    public var expectFamily: FileFamily?
    public var expectDurationS: Double?
    public var maxBytes: UInt64?
    public var mustBeSmallerThan: UInt64?
    public var expectNoLocation: Bool
}

public struct ConversionPlan: Codable, Sendable, Hashable {
    public var engine: EngineKind
    public var outputFormat: FileFormat
    public var outputExtension: String
    public var reencode: Bool
    public var steps: [String]
    public var notes: [PlanNote]?
    public var estimate: SizeEstimate?
    public var image: ImageJob?
    public var ffmpeg: FfmpegJob?
    public var nativeAv: NativeAvJob?
    public var targetBudget: TargetSizeBudget?
    public var verify: VerifySpec
}

// MARK: Actions & output

public enum ActionID: String, Codable, Sendable, Hashable, CaseIterable {
    case makeSmaller = "make_smaller"
    case targetSize = "target_size"
    case convert
    case extractAudio = "extract_audio"
    case createGif = "create_gif"
    case resize
    case webOptimize = "web_optimize"
    case removeMetadata = "remove_metadata"
    case removeLocation = "remove_location"
}

public struct SmartAction: Codable, Sendable, Hashable, Identifiable {
    public var id: ActionID
    public var primary: Bool
    public var formats: [FileFormat]?
}

public enum OutputLocation: Sendable, Hashable, Codable {
    case sameFolder
    case custom(directory: String)

    private enum CodingKeys: String, CodingKey { case kind, directory }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sameFolder: try c.encode("same_folder", forKey: .kind)
        case .custom(let d): try c.encode("custom", forKey: .kind); try c.encode(d, forKey: .directory)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .kind) == "custom" {
            self = .custom(directory: try c.decode(String.self, forKey: .directory))
        } else {
            self = .sameFolder
        }
    }
}

public enum CollisionPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case rename, replace, skip
    public var id: String { rawValue }
}

public struct OutputPolicy: Codable, Sendable, Hashable {
    public var location: OutputLocation
    public var collision: CollisionPolicy

    public init(location: OutputLocation = .sameFolder, collision: CollisionPolicy = .rename) {
        self.location = location; self.collision = collision
    }
}

public struct NamePreview: Codable, Sendable, Hashable {
    public var path: String
    public var fileName: String
    public var collided: Bool
}

public enum FinalizeOutcome: Sendable, Hashable, Decodable {
    case written(path: String, sizeBytes: UInt64, replaced: Bool)
    case skipped(existing: String)

    private enum CodingKeys: String, CodingKey { case status, path, sizeBytes, replaced, existing }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .status) == "skipped" {
            self = .skipped(existing: try c.decode(String.self, forKey: .existing))
        } else {
            self = .written(path: try c.decode(String.self, forKey: .path),
                            sizeBytes: try c.decode(UInt64.self, forKey: .sizeBytes),
                            replaced: try c.decode(Bool.self, forKey: .replaced))
        }
    }
}

public struct JobTempDir: Codable, Sendable { public var jobId: String; public var path: String }

public struct CleanupReport: Codable, Sendable { public var removed: UInt32; public var kept: UInt32; public var freedBytes: UInt64 }

public struct ExecuteResult: Decodable, Sendable {
    public var tempOutput: String
    public var sizeBytes: UInt64
    public var attempts: UInt32
    public var encoder: String?
    public var hardware: Bool
    public var fallbackReason: String?
    public var outputInfo: MediaInfo?
    public var plan: ConversionPlan
}

public struct CoreInfo: Decodable, Sendable {
    public var name: String
    public var version: String
    public var apiVersion: UInt32
    public var webpVersion: String
    public var target: String
}
