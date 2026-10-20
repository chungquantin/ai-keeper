import AppKit

// Draws the 1200x630 social card: white, the logo, the headline and the app. Run: swift og.swift <icon.png> <screenshot.png> <out.png>
let args = CommandLine.arguments
guard args.count == 4, let icon = NSImage(contentsOfFile: args[1]), let shot = NSImage(contentsOfFile: args[2]) else { print("usage"); exit(1) }
let W = 1200, H = 630
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // 1 point = 1 pixel
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let ink = NSColor(red: 0.063, green: 0.094, blue: 0.157, alpha: 1)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

// The window of the screenshot (source pixels, bottom-left origin), drawn bleeding off the right and bottom.
let sw = shot.size.width, sh = shot.size.height
let crop = NSRect(x: sw * 0.034, y: sh * 0.06, width: sw * 0.93, height: sh * 0.9)
let dw: CGFloat = 800, dh = dw * crop.height / crop.width
shot.draw(in: NSRect(x: 470, y: CGFloat(H) - 60 - dh, width: dw, height: dh), from: crop, operation: .sourceOver, fraction: 1)
let fade = NSGradient(colors: [NSColor.white, NSColor.white.withAlphaComponent(0)])!
fade.draw(in: NSRect(x: 440, y: 0, width: 60, height: CGFloat(H)), angle: 0)

func serif(_ pt: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: pt, weight: .medium)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: pt) ?? base
}
icon.draw(in: NSRect(x: 60, y: 520, width: 56, height: 56), from: .zero, operation: .sourceOver, fraction: 1)
("AI Keeper" as NSString).draw(at: NSPoint(x: 128, y: 532), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: ink])
("Your coding agents leave gigabytes behind." as NSString).draw(in: NSRect(x: 60, y: 230, width: 400, height: 250),
    withAttributes: [.font: serif(46), .foregroundColor: ink])
("See what is safe to delete on your Mac, and clean it up in the background." as NSString).draw(in: NSRect(x: 60, y: 110, width: 380, height: 90),
    withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor(red: 0.4, green: 0.44, blue: 0.52, alpha: 1)])
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3]) \(rep.pixelsWide)x\(rep.pixelsHigh)")
