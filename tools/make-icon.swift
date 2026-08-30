// Renders the app icon and writes an .iconset for iconutil.
//
// Drawn rather than sourced: the mark has to say "an Android device, mirrored", and it has to
// stay legible at 16pt in the Dock and the menu bar. So it is one phone silhouette with a play
// triangle in it, on Android's green — no text, no fine detail, nothing that closes up when small.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // macOS icons are a squircle inset from the canvas, not a full-bleed square.
    let inset = size * 0.09
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.2237                     // Big Sur's corner ratio
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    squircle.addClip()
    let bg = NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.86, blue: 0.52, alpha: 1),
                                 NSColor(srgbRed: 0.05, green: 0.55, blue: 0.44, alpha: 1)])!
    bg.draw(in: body, angle: -90)
    ctx.restoreGState()

    // The phone: a rounded outline, deliberately thick so it survives being scaled to 16pt.
    let w = body.width * 0.40, h = body.height * 0.62
    let phone = CGRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h)
    let stroke = max(1, size * 0.035)
    let phonePath = NSBezierPath(roundedRect: phone, xRadius: w * 0.18, yRadius: w * 0.18)
    phonePath.lineWidth = stroke
    NSColor.white.setStroke()
    phonePath.stroke()

    // Play triangle, centred in the screen area — "this device is being streamed".
    let t = w * 0.34
    let tri = NSBezierPath()
    tri.move(to: CGPoint(x: body.midX - t * 0.45, y: body.midY + t * 0.58))
    tri.line(to: CGPoint(x: body.midX - t * 0.45, y: body.midY - t * 0.58))
    tri.line(to: CGPoint(x: body.midX + t * 0.62, y: body.midY))
    tri.close()
    NSColor.white.setFill()
    tri.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// The sizes iconutil expects.
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
                   ("icon_512x512@2x", 1024)] {
    let rep = draw(CGFloat(px))
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(out)")
