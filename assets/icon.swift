import AppKit

// AI Keeper app icon: the pixel Keeper robot on an ultramarine squircle. Run: swift icon.swift <outdir>

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

let ivory: UInt32 = 0xFFFFFF, amber: UInt32 = 0xFFB833, pineTop: UInt32 = 0x4262FF, pineBottom: UInt32 = 0x1C2FD0, inkBlue: UInt32 = 0x1B2BC4

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
    cg.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: color(0x0B1450, 0.40))
    cg.setFillColor(color(pineBottom)); cg.addPath(body); cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(body); cg.clip()
    let g = CGGradient(colorsSpace: space, colors: [color(pineTop), color(pineBottom)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(g, start: CGPoint(x: 300, y: 940), end: CGPoint(x: 700, y: 90), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Light catching the top edge.
    let hi = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(hi, start: CGPoint(x: 512, y: 930), end: CGPoint(x: 512, y: 560), options: [.drawsBeforeStartLocation])
    cg.restoreGState()

        // The Keeper robot, drawn as pixels (the same sprite as the website, the launch film and the app's loading screen).
    let rows = [".....A........", ".....A........", "...WWWWWWWW...", "..WWWWWWWWWW..", "..WWKKWWKKWW..", "..WWKKWWKKWW..", "..WWWWWWWWWW..", "...WWWWWWWW...",
                "..LLLLLLLLLM..", ".LLLLDDDDLLLLM", ".LLLLDYYDLLLLM", ".LLLLDDDDLLLLM", "..LLLLLLLLLM..", "...MMMMMMMM...", ".KKKKK..KKKKK.", "..KKK....KKK.."]
    let pal: [Character: UInt32] = ["W": 0xFFFFFF, "L": 0xDFE5FF, "M": 0x9AA8F5, "K": 0x0C1240, "D": 0x1A2A9A, "Y": 0xFFB020, "A": 0xFFB020]
    var set: [String: UInt32] = [:]
    for (y, r) in rows.enumerated() { for (x, ch) in r.enumerated() where ch != "." { if let c = pal[ch] { set["\(x),\(y)"] = c } } }
    func has(_ x: Int, _ y: Int) -> Bool { set["\(x),\(y)"] != nil }
    let u: CGFloat = 32, w = 14, h = rows.count
    let x0 = 512 - CGFloat(w + 2) * u / 2, top = 512 + CGFloat(h + 2) * u / 2 - 6
    func cell(_ x: Int, _ y: Int, _ c: UInt32) { cg.setFillColor(color(c)); cg.fill(CGRect(x: x0 + CGFloat(x + 1) * u, y: top - CGFloat(y + 2) * u, width: u, height: u)) }
    // soft floor shadow under the wheels
    cg.saveGState()
    cg.setFillColor(color(0x0B1450, 0.32))
    cg.fillEllipse(in: CGRect(x: 512 - 190, y: top - CGFloat(h + 2) * u - 6, width: 380, height: 40))
    cg.restoreGState()
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: color(0x0B1450, 0.38))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)   // one shadow for the whole robot, not one per pixel
    for y in -1...h { for x in -1...w {
        if let c = set["\(x),\(y)"] { cell(x, y, c) }
        else if has(x + 1, y) || has(x - 1, y) || has(x, y + 1) || has(x, y - 1) { cell(x, y, 0x0C1240) }
    } }
    cg.endTransparencyLayer()
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
