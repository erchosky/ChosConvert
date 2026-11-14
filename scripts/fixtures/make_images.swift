// Generates image fixtures with ImageIO. Usage: swift make_images.swift <output-dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(width: Int, height: Int, alpha: Bool) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: info)!
    if alpha { ctx.clear(CGRect(x: 0, y: 0, width: width, height: height)) }
    for i in 0..<12 {
        let t = CGFloat(i) / 12
        ctx.setFillColor(CGColor(red: t, green: 0.4, blue: 1 - t, alpha: alpha ? 0.8 : 1))
        ctx.fill(CGRect(x: CGFloat(i) * CGFloat(width) / 12, y: 0, width: CGFloat(width) / 12, height: CGFloat(height) * (0.3 + t * 0.7)))
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 3))
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String, _ type: UTType, _ props: [CFString: Any] = [:]) {
    let url = out.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(name)")
    }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(name)") }
}

let exif: [CFString: Any] = [
    kCGImagePropertyExifDateTimeOriginal: "2026:05:01 10:30:00",
    kCGImagePropertyExifLensModel: "Fixture Lens 24mm",
    kCGImagePropertyExifUserComment: "ChosConvert fixture",
]
let gps: [CFString: Any] = [
    kCGImagePropertyGPSLatitude: 40.4168, kCGImagePropertyGPSLatitudeRef: "N",
    kCGImagePropertyGPSLongitude: 3.7038, kCGImagePropertyGPSLongitudeRef: "W",
    kCGImagePropertyGPSAltitude: 667.0,
]
let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "FixtureCam", kCGImagePropertyTIFFModel: "FC-1"]

let photo = render(width: 1600, height: 1200, alpha: false)
write(photo, "photo_gps.jpg", .jpeg, [
    kCGImageDestinationLossyCompressionQuality: 0.9,
    kCGImagePropertyExifDictionary: exif, kCGImagePropertyGPSDictionary: gps,
    kCGImagePropertyTIFFDictionary: tiff, kCGImagePropertyOrientation: 6,
])
write(photo, "photo.heic", .heic, [kCGImageDestinationLossyCompressionQuality: 0.7,
                                    kCGImagePropertyGPSDictionary: gps])
write(render(width: 512, height: 512, alpha: true), "logo_alpha.png", .png)
write(render(width: 3000, height: 2000, alpha: false), "large.png", .png)
print("images written")
