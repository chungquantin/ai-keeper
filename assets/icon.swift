import AppKit

// AI Keeper app icon. A "K" drawn as a git branch: a stem and two branches ending in commit nodes.
// Amber is the app's colour for rebuildable space. Run: swift icon.swift <outdir>

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

let ivory: UInt32 = 0xEEF3EE, amber: UInt32 = 0xF4B740, pineTop: UInt32 = 0x17463F, pineBottom: UInt32 = 0x07181A

/// Apple-style squircle (superellipse), not a plain rounded rect.
func squircle(center: CGPoint, half: CGFloat, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = center.x + half * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = center.y + half * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func draw(_ cg: CGContext) {
    let center = CGPoint(x: 512, y: 512)
    let body = squircle(center: center, half: 412)
    let space = CGColorSpaceCreateDeviceRGB()

    // Body with the standard soft drop shadow.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: color(0x000000, 0.45))
    cg.setFillColor(color(pineBottom)); cg.addPath(body); cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(body); cg.clip()
    let g = CGGradient(colorsSpace: space, colors: [color(pineTop), color(pineBottom)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(g, start: CGPoint(x: 300, y: 940), end: CGPoint(x: 700, y: 90), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Light catching the top edge.
    let hi = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.13), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(hi, start: CGPoint(x: 512, y: 930), end: CGPoint(x: 512, y: 560), options: [.drawsBeforeStartLocation])
    // Disk platter, barely there.
    cg.setStrokeColor(color(ivory, 0.07)); cg.setLineWidth(16)
    cg.strokeEllipse(in: CGRect(x: 512 - 318, y: 512 - 318, width: 636, height: 636))
    cg.setLineWidth(5)
    cg.strokeEllipse(in: CGRect(x: 512 - 250, y: 512 - 250, width: 500, height: 500))
    cg.restoreGState()

    // The K: stem + two branches.
    let stemX: CGFloat = 400, top: CGFloat = 744, bottom: CGFloat = 280, join: CGFloat = 512, armX: CGFloat = 648
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 14, color: color(0x000000, 0.4))
    cg.setStrokeColor(color(ivory)); cg.setLineWidth(48); cg.setLineCap(.round); cg.setLineJoin(.round)
    cg.move(to: CGPoint(x: stemX, y: bottom)); cg.addLine(to: CGPoint(x: stemX, y: top))
    cg.move(to: CGPoint(x: stemX, y: join)); cg.addLine(to: CGPoint(x: armX, y: top))
    cg.move(to: CGPoint(x: stemX, y: join)); cg.addLine(to: CGPoint(x: armX, y: bottom))
    cg.strokePath()

    // Commit nodes.
    func node(_ x: CGFloat, _ y: CGFloat, fill: UInt32, r: CGFloat) {
        cg.setFillColor(color(fill)); cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        cg.setFillColor(color(pineBottom)); cg.fillEllipse(in: CGRect(x: x - r * 0.42, y: y - r * 0.42, width: r * 0.84, height: r * 0.84))
    }
    node(stemX, top, fill: ivory, r: 60)
    node(stemX, bottom, fill: ivory, r: 60)
    node(armX, top, fill: ivory, r: 60)
    node(armX, bottom, fill: amber, r: 68)   // the one that's yours to take back
    cg.restoreGState()
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx.cgContext)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let set = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
try! png(1024).write(to: URL(fileURLWithPath: "\(out)/icon-1024.png"))
print("wrote \(set)")
