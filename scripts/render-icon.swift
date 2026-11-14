// Renders the provisional ChosConvert app icon (see branding/ICON_SPEC.md) into an
// AppIcon.appiconset. Usage: swift scripts/render-icon.swift <appiconset-dir>
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

func drawIcon(size s: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 0.098 // macOS icon grid: 824/1024 body
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Shadow + body gradient (indigo → violet).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.3, green: 0.32, blue: 0.85, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.42, green: 0.45, blue: 1.0, alpha: 1),
        CGColor(red: 0.27, green: 0.25, blue: 0.78, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // Two documents: the source (back, translucent) and the result (front, solid).
    func doc(_ r: CGRect, alpha: CGFloat) {
        let fold = r.width * 0.28
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        ctx.fillPath()
    }
    let w = body.width * 0.36, h = body.width * 0.46
    doc(CGRect(x: body.minX + body.width * 0.16, y: body.minY + body.height * 0.30, width: w, height: h), alpha: 0.38)
    doc(CGRect(x: body.minX + body.width * 0.46, y: body.minY + body.height * 0.22, width: w, height: h), alpha: 1)

    // Transformation arrow sweeping from the back document into the front one.
    ctx.setStrokeColor(CGColor(red: 0.30, green: 0.31, blue: 0.86, alpha: 1))
    ctx.setLineWidth(body.width * 0.055)
    ctx.setLineCap(.round)
    let a0 = CGPoint(x: body.minX + body.width * 0.55, y: body.minY + body.height * 0.40)
    let a1 = CGPoint(x: body.minX + body.width * 0.72, y: body.minY + body.height * 0.40)
    ctx.move(to: a0); ctx.addLine(to: a1); ctx.strokePath()
    ctx.move(to: CGPoint(x: a1.x - body.width * 0.06, y: a1.y + body.width * 0.06)); ctx.addLine(to: a1)
    ctx.addLine(to: CGPoint(x: a1.x - body.width * 0.06, y: a1.y - body.width * 0.06)); ctx.strokePath()
    return ctx.makeImage()!
}

let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (pt, scale) in sizes {
    let px = pt * scale
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    let rep = NSBitmapImageRep(cgImage: drawIcon(size: CGFloat(px)))
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("icon rendered")
