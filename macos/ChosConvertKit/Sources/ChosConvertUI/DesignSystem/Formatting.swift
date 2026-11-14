import ChosConvertKit
import Foundation

enum Fmt {
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    static func approxBytes(_ n: UInt64) -> String { "~" + bytes(n) }

    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        f.zeroFormattingBehavior = .pad
        f.unitsStyle = .positional
        return f.string(from: seconds.rounded()) ?? "\(Int(seconds))s"
    }

    static func eta(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return f.string(from: max(1, seconds.rounded())) ?? ""
    }

    static func percent(_ fraction: Double, signed: Bool = false) -> String {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = abs(fraction) < 0.1 ? 1 : 0
        if signed { f.positivePrefix = "+" }
        return f.string(from: NSNumber(value: fraction)) ?? ""
    }

    static func resolution(_ w: UInt32, _ h: UInt32) -> String {
        let short = min(w, h)
        let label: String? = switch short {
        case 2100...: "4K"
        case 1400..<2100: "1440p"
        case 1000..<1400: "1080p"
        case 700..<1000: "720p"
        default: nil
        }
        return label.map { "\($0) · \(w)×\(h)" } ?? "\(w)×\(h)"
    }

    static func codec(_ c: String) -> String {
        switch c {
        case "h264": "H.264"
        case "hevc": "HEVC"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "prores": "ProRes"
        case "aac": "AAC"
        case "mp3": "MP3"
        case "opus": "Opus"
        case "flac": "FLAC"
        case "alac": "ALAC"
        case "vorbis": "Vorbis"
        case let p where p.hasPrefix("pcm_"): "PCM"
        default: c.uppercased()
        }
    }

    static func channels(_ n: UInt32) -> String {
        switch n {
        case 1: L.s("audio.mono")
        case 2: L.s("audio.stereo")
        case 6: "5.1"
        case 8: "7.1"
        default: L.f("audio.channels", Int(n))
        }
    }

    /// One-line technical summary: "4K · HEVC · 43:28 · 1.42 GB".
    static func summary(_ m: MediaInfo) -> [String] {
        var parts: [String] = []
        if let v = m.primaryVideo {
            let (w, h) = v.displaySize
            parts.append(resolution(w, h))
            parts.append(codec(v.codec) + (v.hdr ? " HDR" : ""))
        } else if let img = m.image {
            let (w, h) = img.displaySize
            parts.append("\(w)×\(h)")
        }
        if m.primaryVideo == nil, let a = m.primaryAudio {
            parts.append(codec(a.codec))
            if let sr = a.sampleRate { parts.append(String(format: "%.1f kHz", Double(sr) / 1000)) }
            if let ch = a.channels { parts.append(channels(ch)) }
        }
        if let pdf = m.pdf { parts.append(L.f("pdf.pages", Int(pdf.pageCount))) }
        if let d = m.durationS { parts.append(duration(d)) }
        parts.append(bytes(m.sizeBytes))
        return parts
    }
}
