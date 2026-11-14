import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import PDFKit

/// Inspects files without loading them into memory: content detection in the core, then
/// ImageIO property reads for images, FFprobe (or AVFoundation) for media and PDFKit for PDFs.
public enum Inspector {
    struct PathRequest: Encodable { var path: String }
    struct ProbeRequest: Encodable { var path: String; var ffprobePath: String }

    public static func detect(_ url: URL) async throws(ChosError) -> Detection {
        let path = url.path
        return try await offMain { () throws(ChosError) -> Detection in
            try CoreBridge.call("detect.path", PathRequest(path: path))
        }
    }

    public static func inspect(_ url: URL, capabilities: Capabilities) async throws(ChosError) -> MediaInfo {
        let detection = try await detect(url)
        if detection.warnings?.contains("truncated") == true {
            throw ChosError(code: "corrupt_file", category: "input",
                            message: "This file is incomplete. It may not have finished downloading or copying.",
                            recovery: ["check_file"])
        }
        switch detection.family {
        case .executable:
            throw ChosError(code: "executable_rejected", category: "input",
                            message: "This file is a program, not a document or media file. ChosConvert won't process it.")
        case .unknown:
            throw ChosError(code: "unknown_format", category: "input",
                            message: "ChosConvert doesn't recognize this file's format.", recovery: ["check_file"])
        case .image:
            return try await offMain { () throws(ChosError) -> MediaInfo in
                try inspectImage(url, detection: detection)
            }
        case .video, .audio:
            if let ffprobe = capabilities.ffmpeg?.ffprobePath {
                return try await CoreBridge.runTask("media.probe", ProbeRequest(path: url.path, ffprobePath: ffprobe),
                                                    as: MediaInfo.self) { _ in }
            }
            return try await inspectAV(url, detection: detection)
        case .pdf:
            return try await offMain { () throws(ChosError) -> MediaInfo in
                try inspectPDF(url, detection: detection)
            }
        case .document, .archive:
            return base(url, detection, inspector: "detect")
        }
    }

    static func base(_ url: URL, _ d: Detection, inspector: String) -> MediaInfo {
        MediaInfo(path: url.path, fileName: url.lastPathComponent, sizeBytes: d.sizeBytes, detection: d,
                  family: d.family, inspector: inspector)
    }

    static func corrupt(_ details: String) -> ChosError {
        ChosError(code: "corrupt_file", category: "input", message: "This file couldn't be read. It may be damaged or incomplete.",
                  recovery: ["check_file"], details: details)
    }

    // MARK: Images

    static func inspectImage(_ url: URL, detection: Detection) throws(ChosError) -> MediaInfo {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any] else {
            throw corrupt("ImageIO could not open the image")
        }
        let status = CGImageSourceGetStatusAtIndex(src, 0)
        guard status == .statusComplete else {
            throw corrupt("ImageIO status \(status.rawValue)")
        }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.uint32Value ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.uint32Value ?? 0
        guard w > 0, h > 0 else { throw corrupt("missing dimensions") }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        var metadata: [MetadataEntry] = []
        func add(_ key: String, _ value: Any?, sensitive: Bool) {
            guard let value else { return }
            metadata.append(MetadataEntry(key: key, value: "\(value)", sensitive: sensitive))
        }
        add("Make", tiff?[kCGImagePropertyTIFFMake], sensitive: true)
        add("Model", tiff?[kCGImagePropertyTIFFModel], sensitive: true)
        add("Software", tiff?[kCGImagePropertyTIFFSoftware], sensitive: false)
        add("DateTimeOriginal", exif?[kCGImagePropertyExifDateTimeOriginal], sensitive: true)
        add("LensModel", exif?[kCGImagePropertyExifLensModel], sensitive: true)
        add("BodySerialNumber", exif?[kCGImagePropertyExifBodySerialNumber], sensitive: true)
        add("UserComment", exif?[kCGImagePropertyExifUserComment], sensitive: true)
        if let gps {
            let lat = gps[kCGImagePropertyGPSLatitude].map { "\($0)\(gps[kCGImagePropertyGPSLatitudeRef] ?? "")" }
            let lon = gps[kCGImagePropertyGPSLongitude].map { "\($0)\(gps[kCGImagePropertyGPSLongitudeRef] ?? "")" }
            add("GPSPosition", [lat, lon].compactMap { $0 }.joined(separator: ", "), sensitive: true)
            add("GPSAltitude", gps[kCGImagePropertyGPSAltitude], sensitive: true)
        }

        let info = ImageInfo(
            width: w, height: h,
            bitDepth: (props[kCGImagePropertyDepth] as? NSNumber)?.uint32Value,
            hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false,
            colorModel: props[kCGImagePropertyColorModel] as? String,
            colorProfile: props[kCGImagePropertyProfileName] as? String,
            dpi: (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
            orientation: (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
            frameCount: UInt32(CGImageSourceGetCount(src)),
            hasExif: exif != nil && !(exif?.isEmpty ?? true),
            hasGps: gps != nil && !(gps?.isEmpty ?? true)
        )
        var m = base(url, detection, inspector: "imageio")
        m.image = info
        m.metadata = metadata
        m.hasLocation = info.hasGps
        return m
    }

    // MARK: Audio / video (AVFoundation fallback when FFprobe isn't available)

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    static func codecName(_ fourcc: String, bitDepth: Int? = nil) -> String {
        switch fourcc {
        case "avc1", "avc3": "h264"
        case "hvc1", "hev1", "dvh1", "dvhe": "hevc"
        case "av01": "av1"
        case "vp09": "vp9"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": "prores"
        case "jpeg": "mjpeg"
        case "aac", "mp4a": "aac"
        case "alac": "alac"
        case ".mp3": "mp3"
        case "flac": "flac"
        case "opus": "opus"
        case "ac-3": "ac3"
        case "ec-3": "eac3"
        case "lpcm": (bitDepth ?? 16) > 16 ? "pcm_s24le" : "pcm_s16le"
        default: fourcc
        }
    }

    static func inspectAV(_ url: URL, detection: Detection) async throws(ChosError) -> MediaInfo {
        let asset = AVURLAsset(url: url)
        do {
            let (duration, tracks, metadataItems) = try await asset.load(.duration, .tracks, .metadata)
            var m = base(url, detection, inspector: "avfoundation")
            m.durationS = duration.isNumeric ? duration.seconds : nil
            for (i, track) in tracks.enumerated() {
                let (formats, rate) = try await track.load(.formatDescriptions, .estimatedDataRate)
                let desc = formats.first
                let sub = desc.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
                switch track.mediaType {
                case .video:
                    let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                    let angle = Int32((atan2(transform.b, transform.a) * 180 / .pi).rounded())
                    let ext = desc.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] }
                    let transfer = ext?[kCVImageBufferTransferFunctionKey as String] as? String
                    let hdr = transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
                        || transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                    m.video.append(VideoStream(index: UInt32(i), codec: codecName(sub), width: UInt32(size.width),
                                               height: UInt32(size.height), fps: fps > 0 ? Double(fps) : nil,
                                               bitRate: rate > 0 ? UInt64(rate) : nil, hdr: hdr,
                                               rotation: (angle % 360 + 360) % 360))
                case .audio:
                    let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                    let depth = asbd.map { Int($0.mBitsPerChannel) }
                    m.audio.append(AudioStream(index: UInt32(i), codec: codecName(sub, bitDepth: depth),
                                               sampleRate: asbd.map { UInt32($0.mSampleRate) },
                                               channels: asbd.map { UInt32($0.mChannelsPerFrame) },
                                               bitRate: rate > 0 ? UInt64(rate) : nil,
                                               bitDepth: depth.flatMap { $0 > 0 ? UInt32($0) : nil }))
                case .metadata:
                    m.hasLocation = true // timed metadata tracks (e.g. iPhone location) are treated as sensitive
                default:
                    break
                }
            }
            for item in metadataItems {
                let key = item.identifier?.rawValue ?? item.commonKey?.rawValue ?? "unknown"
                let value = (try? await item.load(.stringValue)) ?? ""
                let sensitive = key.localizedCaseInsensitiveContains("location") || key.contains("make")
                    || key.contains("model") || key.contains("creationdate") || key.contains("artist")
                if key.localizedCaseInsensitiveContains("location") { m.hasLocation = true }
                m.metadata.append(MetadataEntry(key: key, value: value, sensitive: sensitive))
            }
            guard !m.video.isEmpty || !m.audio.isEmpty else {
                throw corrupt("no audio or video tracks")
            }
            m.family = m.video.isEmpty ? .audio : .video
            if let d = m.durationS, d > 0 { m.bitRate = UInt64(Double(m.sizeBytes * 8) / d) }
            return m
        } catch let e as ChosError {
            throw e
        } catch {
            throw corrupt("AVFoundation: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    // MARK: PDF

    static func inspectPDF(_ url: URL, detection: Detection) throws(ChosError) -> MediaInfo {
        guard let doc = PDFDocument(url: url) else { throw corrupt("PDFKit could not open the document") }
        var m = base(url, detection, inspector: "pdfkit")
        m.pdf = PdfInfo(pageCount: UInt32(doc.pageCount), version: "\(doc.majorVersion).\(doc.minorVersion)",
                        encrypted: doc.isEncrypted, locked: doc.isLocked)
        if !doc.isLocked, let attrs = doc.documentAttributes {
            for (k, v) in attrs {
                let key = "\(k)"
                m.metadata.append(MetadataEntry(key: key, value: "\(v)",
                                                sensitive: ["Author", "Creator", "Producer", "CreationDate", "ModDate"].contains(key)))
            }
        }
        return m
    }
}
