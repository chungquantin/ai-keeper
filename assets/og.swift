import AppKit

// Draws the 1200x630 social card. Run: swift og.swift <icon.png> <window-capture.png> <out.png>
// The capture is the full-screen-size PNG written by the screenshot tool (AIKEEPER_SHOTS), with its window shadow.
let args = CommandLine.arguments
guard args.count == 4, let icon = NSImage(contentsOfFile: args[1]), let shot = NSImage(contentsOfFile: args[2]) else { print("usage"); exit(1) }
let W = 1200, H = 630
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // 1 point = 1 pixel
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
let ink = rgb(14, 17, 22), slate = rgb(91, 100, 114)

// Paper, then the floor the window sits on.
rgb(255, 255, 255).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
NSGradient(colors: [rgb(255, 255, 255), rgb(241, 243, 247)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 35)

// The window: exact bounds of the capture (2944x2184: x 112, y 76, 2719x1959), rounded like macOS, bleeding off the right and bottom.
let sw = shot.size.width, sh = shot.size.height
let crop = NSRect(x: sw * 112 / 2944, y: sh * (2184 - 76 - 1959) / 2184, width: sw * 2719 / 2944, height: sh * 1959 / 2184)
let dw: CGFloat = 820, dh = dw * crop.height / crop.width
let frame = NSRect(x: 400, y: CGFloat(H) - 78 - dh, width: dw, height: dh)
let r = dw * 0.0188
let path = NSBezierPath(roundedRect: frame, xRadius: r, yRadius: dh * 0.026)
ctx.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 48; shadow.shadowOffset = NSSize(width: 0, height: -22)
shadow.set(); NSColor.white.setFill(); path.fill()
ctx.restoreGraphicsState()
ctx.saveGraphicsState()
path.addClip()
shot.draw(in: frame, from: crop, operation: .sourceOver, fraction: 1)
ctx.restoreGraphicsState()
NSColor.black.withAlphaComponent(0.14).setStroke(); path.lineWidth = 1; path.stroke()

// Left column.
let iconRect = NSRect(x: 64, y: 524, width: 56, height: 56)
icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
("AI Keeper" as NSString).draw(at: NSPoint(x: 134, y: 536), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: ink, .kern: -0.6])
let head = NSMutableParagraphStyle(); head.lineSpacing = -4
("Your coding agents leave gigabytes behind." as NSString).draw(in: NSRect(x: 64, y: 190, width: 400, height: 300),
    withAttributes: [.font: NSFont.systemFont(ofSize: 54, weight: .heavy), .foregroundColor: ink, .kern: -2.2, .paragraphStyle: head])
("Find what is safe to delete on your Mac and clear it in the background." as NSString).draw(in: NSRect(x: 64, y: 78, width: 330, height: 80),
    withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .regular), .foregroundColor: slate])
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3]) \(rep.pixelsWide)x\(rep.pixelsHigh)")
