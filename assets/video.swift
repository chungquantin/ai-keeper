import AppKit

// Turns the recorded frames into the demo video: title card, the app on the floor with captions, outro card.
// Run: swift video.swift <recording dir> <icon.png> <out.mp4>   (needs ffmpeg on PATH)
let args = CommandLine.arguments
guard args.count == 4 else { print("usage: video.swift <dir> <icon> <out.mp4>"); exit(1) }
let dir = URL(fileURLWithPath: args[1])
guard let icon = NSImage(contentsOfFile: args[2]),
      let raw = try? Data(contentsOf: dir.appendingPathComponent("timeline.json")),
      let info = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      let frameList = info["frames"] as? [[Double]], let events = info["events"] as? [[String: Any]],
      let duration = info["duration"] as? Double, !frameList.isEmpty else { print("bad recording"); exit(1) }

let W = 1920, H = 1080, FPS = 30.0
let intro = 3.2, outro = 4.2, fade = 0.7
let total = intro + duration + outro
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
let ink = rgb(14, 17, 22), slate = rgb(91, 100, 114), cobalt = rgb(37, 69, 245)
let captions: [(t: Double, text: String)] = events.compactMap { e in
    guard let t = e["t"] as? Double, let c = e["caption"] as? String else { return nil }
    return (t, c)
}

func ease(_ p: Double) -> Double { let q = min(1, max(0, p)); return q * q * (3 - 2 * q) }
func loadFrame(_ i: Int) -> CGImage? {
    let url = dir.appendingPathComponent(String(format: "frame_%05d.png", i))
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

let ffmpeg = Process()
ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
ffmpeg.arguments = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "\(W)x\(H)", "-framerate", "\(Int(FPS))", "-i", "-",
                    "-c:v", "libx264", "-crf", "17", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart", args[3]]
let pipe = Pipe(); ffmpeg.standardInput = pipe
try! ffmpeg.run()

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctxCG = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
let ns = NSGraphicsContext(cgContext: ctxCG, flipped: false)

func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint, kern: CGFloat = 0, align: NSTextAlignment = .left, width: CGFloat? = nil, alpha: CGFloat = 1) {
    let para = NSMutableParagraphStyle(); para.alignment = align; para.lineSpacing = -2
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(color.alphaComponent * alpha), .kern: kern, .paragraphStyle: para]
    // With a width, p.y is the TOP of the block, so stacked blocks can't collide.
    if let w = width {
        let h = ceil((s as NSString).boundingRect(with: NSSize(width: w, height: 1000), options: [.usesLineFragmentOrigin], attributes: attrs).height)
        (s as NSString).draw(in: NSRect(x: p.x, y: p.y - h, width: w, height: h), withAttributes: attrs)
    }
    else { (s as NSString).draw(at: p, withAttributes: attrs) }
}

func background() {
    NSGradient(colors: [rgb(255, 255, 255), rgb(241, 243, 247)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 35)
}

func titleCard(alpha: Double, lift: Double) {
    let a = CGFloat(alpha), dy = CGFloat(lift)
    icon.draw(in: NSRect(x: CGFloat(W) / 2 - 56, y: 850 + dy, width: 112, height: 112), from: .zero, operation: .sourceOver, fraction: a)
    text("Your coding agents\nleave gigabytes behind.", NSFont.systemFont(ofSize: 104, weight: .heavy), ink, at: NSPoint(x: 160, y: 810 + dy), kern: -4.4, align: .center, width: CGFloat(W) - 320, alpha: a)
    text("AI Keeper finds what they left on your Mac and clears it in the background.", NSFont.systemFont(ofSize: 34), slate, at: NSPoint(x: 160, y: 520 + dy), align: .center, width: CGFloat(W) - 320, alpha: a)
}

func outroCard(alpha: Double, lift: Double) {
    let a = CGFloat(alpha), dy = CGFloat(lift)
    icon.draw(in: NSRect(x: CGFloat(W) / 2 - 56, y: 850 + dy, width: 112, height: 112), from: .zero, operation: .sourceOver, fraction: a)
    text("Get your disk back.", NSFont.systemFont(ofSize: 104, weight: .heavy), ink, at: NSPoint(x: 160, y: 810 + dy), kern: -4.4, align: .center, width: CGFloat(W) - 320, alpha: a)
    text("Free for macOS 14 or later", NSFont.systemFont(ofSize: 34), slate, at: NSPoint(x: 160, y: 665 + dy), align: .center, width: CGFloat(W) - 320, alpha: a)
    let box = NSRect(x: CGFloat(W) / 2 - 420, y: 450 + dy, width: 840, height: 104)
    let path = NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16)
    ns.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.18 * a); sh.shadowBlurRadius = 36; sh.shadowOffset = NSSize(width: 0, height: -14); sh.set()
    ink.withAlphaComponent(a).setFill(); path.fill()
    ns.restoreGraphicsState()
    let mono = NSFont.monospacedSystemFont(ofSize: 25, weight: .medium)
    text("$ brew tap chungquantin/ai-keeper", mono, rgb(223, 228, 236), at: NSPoint(x: box.minX + 36, y: box.minY + 58), alpha: a)
    text("$ brew install --cask ai-keeper", mono, rgb(223, 228, 236), at: NSPoint(x: box.minX + 36, y: box.minY + 22), alpha: a)
    text("github.com/chungquantin/ai-keeper", NSFont.systemFont(ofSize: 30, weight: .semibold), cobalt, at: NSPoint(x: 160, y: 390 + dy), align: .center, width: CGFloat(W) - 320, alpha: a)
}

var cache: (Int, CGImage)?
func frameImage(at t: Double) -> CGImage? {
    var idx = frameList[0][0]
    var lo = 0, hi = frameList.count - 1
    while lo <= hi { let mid = (lo + hi) / 2; if frameList[mid][1] <= t { idx = frameList[mid][0]; lo = mid + 1 } else { hi = mid - 1 } }
    let i = Int(idx)
    if let c = cache, c.0 == i { return c.1 }
    guard let img = loadFrame(i) else { return cache?.1 }
    cache = (i, img); return img
}

func drawApp(at t: Double, alpha: Double, scale: Double, captionAlpha: Double) {
    guard let img = frameImage(at: t) else { return }
    // Fit the recording (window plus its shadow margin) into the area above the caption.
    let maxH = 940.0, ar = Double(img.width) / Double(img.height)
    let h = maxH * scale, w = h * ar
    let rect = NSRect(x: (Double(W) - w) / 2, y: 112 + (maxH - h) / 2, width: w, height: h)
    ctxCG.saveGState()
    ctxCG.setAlpha(CGFloat(alpha)); ctxCG.interpolationQuality = .high
    ctxCG.draw(img, in: rect)
    ctxCG.restoreGState()
    // Caption: the last event that has started.
    guard let cap = captions.last(where: { $0.t <= t }) else { return }
    let age = t - cap.t
    let ca = CGFloat(ease(age / 0.35) * captionAlpha * alpha)
    let font = NSFont.systemFont(ofSize: 40, weight: .semibold)
    let size = (cap.text as NSString).size(withAttributes: [.font: font, .kern: -0.6])
    let pill = NSRect(x: (CGFloat(W) - size.width) / 2 - 44, y: 38 - CGFloat(1 - ease(age / 0.35)) * 14, width: size.width + 88, height: 84)
    let path = NSBezierPath(roundedRect: pill, xRadius: 42, yRadius: 42)
    ns.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.16 * ca); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
    NSColor.white.withAlphaComponent(ca).setFill(); path.fill()
    ns.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.08 * ca).setStroke(); path.lineWidth = 1; path.stroke()
    text(cap.text, font, ink, at: NSPoint(x: pill.minX + 44, y: pill.minY + 22), kern: -0.6, alpha: ca)
}

let frameCount = Int(total * FPS)
let bytes = W * H * 4
for n in 0..<frameCount {
    let T = Double(n) / FPS
    NSGraphicsContext.current = ns
    ctxCG.clear(CGRect(x: 0, y: 0, width: W, height: H))
    background()
    if T < intro {
        let p = ease((T - 0.15) / 0.8), out = 1 - ease((T - (intro - fade)) / fade)
        titleCard(alpha: p * out, lift: (1 - p) * -24 - 170)
    } else if T < intro + duration {
        let r = T - intro
        let inP = ease(r / fade)
        drawApp(at: r, alpha: inP, scale: 0.965 + 0.035 * inP, captionAlpha: 1)
    } else {
        let r = T - intro - duration
        let outP = ease(r / fade)
        drawApp(at: duration, alpha: 1 - outP, scale: 1 - 0.035 * outP, captionAlpha: 1 - outP)
        let p = ease((r - 0.2) / 0.8)
        outroCard(alpha: p, lift: (1 - p) * -24 - 150)
    }
    pipe.fileHandleForWriting.write(Data(bytes: ctxCG.data!, count: bytes))
    if n % 90 == 0 { print("frame \(n)/\(frameCount)") }
}
try! pipe.fileHandleForWriting.close()
ffmpeg.waitUntilExit()
print("wrote \(args[3])")
