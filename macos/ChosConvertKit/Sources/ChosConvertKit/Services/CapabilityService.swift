import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Discovers what this Mac can do: ImageIO codecs, AVFoundation export presets and,
/// when present, an FFmpeg build. Discovery runs off the main thread and is cached.
public actor CapabilityService {
    public static let shared = CapabilityService()

    private var cached: Capabilities?
    private var inFlight: Task<Capabilities, Never>?

    /// Optional user-configured FFmpeg location (Settings ▸ Advanced).
    private var customFFmpegPath: String?

    public init() {}

    public func setCustomFFmpegPath(_ path: String?) {
        customFFmpegPath = path?.isEmpty == true ? nil : path
        cached = nil
    }

    public func current() async -> Capabilities {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        let custom = customFFmpegPath
        let task = Task.detached(priority: .utility) { Self.discover(customFFmpegPath: custom) }
        inFlight = task
        let caps = await task.value
        cached = caps
        inFlight = nil
        return caps
    }

    public func refresh() async -> Capabilities {
        cached = nil
        return await current()
    }

    // MARK: Discovery

    static func discover(customFFmpegPath: String?) -> Capabilities {
        let started = Date()
        let caps = Capabilities(
            platform: platform(),
            nativeImage: nativeImage(),
            nativeAv: nativeAv(),
            coreWebp: true,
            ffmpeg: ffmpeg(customPath: customFFmpegPath),
            pdfNative: true,
            ocrNative: false // Exposed once the Vision OCR engine ships (ROADMAP Phase 3).
        )
        Log.capabilities.info("capabilities discovered in \(Date().timeIntervalSince(started), format: .fixed(precision: 3))s; ffmpeg=\(caps.ffmpeg != nil)")
        return caps
    }

    static func platform() -> PlatformInfo {
        let p = ProcessInfo.processInfo
        let v = p.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return PlatformInfo(os: .macos, arch: arch,
                            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                            cpuCount: UInt32(p.activeProcessorCount), memoryBytes: p.physicalMemory)
    }

    static let utiToFormat: [String: FileFormat] = [
        UTType.jpeg.identifier: .jpeg, UTType.png.identifier: .png, UTType.gif.identifier: .gif,
        UTType.webP.identifier: .webp, "public.avif": .avif, UTType.heic.identifier: .heic,
        "public.heif": .heic, UTType.tiff.identifier: .tiff, UTType.bmp.identifier: .bmp,
    ]

    static func nativeImage() -> NativeImageCaps {
        let read = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap { utiToFormat[$0] }
        let write = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).compactMap { utiToFormat[$0] }
        // SVG input is not offered yet: it needs a rasterizer verified not to fetch external
        // resources (ROADMAP Phase 3).
        return NativeImageCaps(read: Array(Set(read)).sorted { $0.rawValue < $1.rawValue },
                               write: Array(Set(write)).sorted { $0.rawValue < $1.rawValue })
    }

    static func nativeAv() -> NativeAvCaps {
        let presets = Set(AVAssetExportSession.allExportPresets())
        return NativeAvCaps(
            available: true,
            h264Encode: presets.contains(AVAssetExportPreset1920x1080),
            hevcEncode: presets.contains(AVAssetExportPresetHEVCHighestQuality),
            aacEncode: presets.contains(AVAssetExportPresetAppleM4A),
            alacEncode: true
        )
    }

    /// FFmpeg lookup order: bundled helper → user setting → well-known install locations.
    /// Sandboxed builds can only execute the bundled helper.
    static func ffmpegCandidates(customPath: String?) -> [URL] {
        var dirs: [URL] = []
        if let helpers = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.deletingLastPathComponent() {
            dirs.append(helpers)
        }
        if let customPath { dirs.append(URL(fileURLWithPath: customPath).deletingLastPathComponent()) }
        if !isSandboxed {
            dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"].map { URL(fileURLWithPath: $0) }
        }
        return dirs
    }

    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static func ffmpeg(customPath: String?) -> FfmpegCaps? {
        let fm = FileManager.default
        for dir in ffmpegCandidates(customPath: customPath) {
            let ff = dir.appendingPathComponent("ffmpeg")
            let fp = dir.appendingPathComponent("ffprobe")
            guard fm.isExecutableFile(atPath: ff.path) else { continue }
            struct Req: Encodable { var ffmpegPath: String; var ffprobePath: String? }
            do {
                let caps: FfmpegCaps = try CoreBridge.call(
                    "capabilities.probe_ffmpeg",
                    Req(ffmpegPath: ff.path, ffprobePath: fm.isExecutableFile(atPath: fp.path) ? fp.path : nil))
                Log.capabilities.info("ffmpeg \(caps.version, privacy: .public) license=\(caps.license, privacy: .public) encoders=\(caps.encoders.count)")
                return caps
            } catch {
                Log.capabilities.error("ffmpeg probe failed: \(error.code, privacy: .public)")
            }
        }
        return nil
    }
}
