import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Native image engine: ImageIO decode/encode, Core Graphics color conversion, and the core's
/// libwebp for WebP output. Decoding goes through ImageIO's downsampling path, so images are
/// never decoded at full size when a smaller result is requested.
public enum ImageIOEngine {
    static func uti(_ f: FileFormat) -> CFString? {
        switch f {
        case .jpeg: UTType.jpeg.identifier as CFString
        case .png: UTType.png.identifier as CFString
        case .gif: UTType.gif.identifier as CFString
        case .heic: UTType.heic.identifier as CFString
        case .avif: "public.avif" as CFString
        case .tiff: UTType.tiff.identifier as CFString
        case .bmp: UTType.bmp.identifier as CFString
        default: nil
        }
    }

    static func fail(_ msg: String, _ details: String) -> ChosError {
        ChosError(code: "encoder_failed", category: "engine", message: msg, recovery: ["choose_other_format"], details: details)
    }

    /// Runs `job` on `input`, writing to `output` (a fresh temp path). Honors task cancellation.
    public static func run(_ job: ImageJob, input: URL, output: URL) throws(ChosError) {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(input as CFURL, srcOpts), CGImageSourceGetCount(src) > 0 else {
            throw ChosError(code: "corrupt_file", category: "input", message: "This image couldn't be read. It may be damaged.",
                            recovery: ["check_file"])
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, srcOpts) as? [CFString: Any]) ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0 else { throw ChosError(code: "corrupt_file", category: "input", message: "This image has no pixels.") }
        guard UInt64(w) * UInt64(h) <= job.maxPixels else {
            throw ChosError(code: "image_too_large", category: "resource", message: "This image is too large to process safely.",
                            details: "\(w)x\(h)")
        }
        if Task.isCancelled { throw .cancelled }

        if job.metadataOnly {
            try rewriteMetadata(src: src, props: props, job: job, output: output)
            return
        }

        // Decode (with EXIF orientation applied) at the requested size.
        let longest = max(w, h)
        let target = job.maxDimension.map { min(Int($0), longest) } ?? longest
        let decodeOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(src, 0, decodeOpts as CFDictionary) else {
            throw ChosError(code: "corrupt_file", category: "input", message: "This image couldn't be decoded. It may be damaged.",
                            recovery: ["check_file"])
        }
        if Task.isCancelled { throw .cancelled }

        let needsRender = job.convertToSrgb || job.flattenBackground != nil || job.encoder == .coreWebp
        if needsRender {
            image = try render(image, flatten: job.flattenBackground)
        }
        if Task.isCancelled { throw .cancelled }

        switch job.encoder {
        case .coreWebp:
            try encodeWebP(image, job: job, output: output)
        case .native:
            try encodeNative(image, sourceProps: props, job: job, output: output)
        }
        try verify(output: output, job: job, expected: (image.width, image.height))
    }

    /// Draws into an 8-bit sRGB context, optionally flattening alpha onto a background.
    static func render(_ image: CGImage, flatten: [UInt8]?) throws(ChosError) -> CGImage {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw .internalError("no sRGB") }
        let alpha: CGImageAlphaInfo = flatten == nil ? .premultipliedLast : .noneSkipLast
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: srgb, bitmapInfo: alpha.rawValue) else {
            throw .internalError("cannot create bitmap context \(image.width)x\(image.height)")
        }
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if let bg = flatten, bg.count == 3 {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(bg[0]) / 255, green: CGFloat(bg[1]) / 255, blue: CGFloat(bg[2]) / 255, alpha: 1))
            ctx.fill(rect)
        }
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else { throw .internalError("render failed") }
        return out
    }

    static func destinationProperties(sourceProps: [CFString: Any], job: ImageJob) -> [CFString: Any] {
        var p: [CFString: Any] = [:]
        if let q = job.quality, !job.lossless { p[kCGImageDestinationLossyCompressionQuality] = q }
        switch job.metadata {
        case .keep, .stripLocation:
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
                if var dict = sourceProps[key] as? [CFString: Any] {
                    // Orientation is baked into the pixels.
                    dict.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                    dict.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                    dict.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                    p[key] = dict
                }
            }
            if job.metadata == .keep, let gps = sourceProps[kCGImagePropertyGPSDictionary] {
                p[kCGImagePropertyGPSDictionary] = gps
            }
        case .stripAll:
            break
        }
        p[kCGImagePropertyOrientation] = 1
        return p
    }

    static func encodeNative(_ image: CGImage, sourceProps: [CFString: Any], job: ImageJob, output: URL) throws(ChosError) {
        guard let type = uti(job.outputFormat),
              let dest = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw fail("This image format can't be written on this Mac.", "no destination for \(job.outputFormat.rawValue)")
        }
        CGImageDestinationAddImage(dest, image, destinationProperties(sourceProps: sourceProps, job: job) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw fail("The image couldn't be encoded.", "CGImageDestinationFinalize failed for \(job.outputFormat.rawValue)")
        }
    }

    static func encodeWebP(_ image: CGImage, job: ImageJob, output: URL) throws(ChosError) {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw .internalError("no sRGB") }
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var vb = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: bytesPerRow)
            // libwebp expects straight (non-premultiplied) alpha.
            return vImageUnpremultiplyData_RGBA8888(&vb, &vb, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard drawn else { throw .internalError("webp: could not prepare pixels") }
        let encoded: Result<Data, ChosError> = buffer.withUnsafeBytes { raw in
            do throws(ChosError) {
                return .success(try CoreBridge.encodeWebP(rgba: raw, width: width, height: height, bytesPerRow: bytesPerRow,
                                                          quality: job.quality ?? 0.82, lossless: job.lossless))
            } catch {
                return .failure(error)
            }
        }
        let data = try encoded.get()
        do {
            try data.write(to: output, options: [.withoutOverwriting])
        } catch {
            throw ChosError.wrap(error)
        }
    }

    /// Lossless metadata edit: pixels are copied untouched.
    static func rewriteMetadata(src: CGImageSource, props: [CFString: Any], job: ImageJob, output: URL) throws(ChosError) {
        guard let type = CGImageSourceGetType(src),
              let dest = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw fail("This image's metadata can't be rewritten.", "no destination")
        }
        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if job.metadata == .stripAll {
            let fresh = CGImageMetadataCreateMutable()
            if let o = props[kCGImagePropertyOrientation] as? NSNumber {
                // Keep orientation so the photo still displays upright.
                CGImageMetadataSetValueMatchingImageProperty(fresh, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, o)
            }
            options[kCGImageDestinationMetadata] = fresh
            options[kCGImageDestinationMergeMetadata] = false
            options[kCGImageMetadataShouldExcludeXMP] = true
        } else if let existing = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
                  let copy = CGImageMetadataCreateMutableCopy(existing) {
            // Keep everything except location: merge the original metadata back, minus GPS.
            options[kCGImageDestinationMetadata] = copy
            options[kCGImageDestinationMergeMetadata] = true
        }
        var cfError: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &cfError) else {
            let msg = cfError.map { "\($0.takeRetainedValue())" } ?? "unknown"
            throw fail("This image's metadata couldn't be removed.", msg)
        }
        try verify(output: output, job: job, expected: nil)
    }

    /// Re-reads the written file: it must decode and must not carry stripped metadata.
    static func verify(output: URL, job: ImageJob, expected: (Int, Int)?) throws(ChosError) {
        guard let src = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(src) > 0,
              CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw ChosError.outputInvalid("written image does not decode")
        }
        if let (ew, eh) = expected {
            let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            guard w == ew, h == eh else { throw ChosError.outputInvalid("dimensions \(w)x\(h), expected \(ew)x\(eh)") }
        }
        if job.metadata != .keep, let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            throw ChosError.outputInvalid("GPS metadata still present")
        }
        if job.metadata == .stripAll, let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let personal: [CFString] = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifLensModel,
                                        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifUserComment]
            if personal.contains(where: { exif[$0] != nil }) {
                throw ChosError.outputInvalid("EXIF metadata still present")
            }
        }
        if job.metadata == .stripAll, let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil {
            throw ChosError.outputInvalid("camera metadata still present")
        }
    }
}
