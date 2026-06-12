// Generates AppIcon.iconset/*.png — run with `swift gen-icon.swift`, then
// `iconutil -c icns AppIcon.iconset -o AppIcon.icns`.
import AppKit

func makeRep(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    return rep
}

func whiteSymbol(_ name: String, points: CGFloat) -> NSImage? {
    let conf = NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(conf), base.size.width > 0 else { return nil }
    let size = base.size
    let rep = makeRep(Int(ceil(size.width)), Int(ceil(size.height)))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    base.draw(in: NSRect(origin: .zero, size: size))
    NSColor.white.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    let out = NSImage(size: size)
    out.addRepresentation(rep)
    return out
}

func makeRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    return rep
}

func renderIcon(_ px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let rep = makeRep(px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple icon grid: squircle inset ~10%, corner radius ~22.5% of its width
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // soft drop shadow
    if px >= 64 {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.shadowBlurRadius = s * 0.02
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // blue → teal gradient, matching the app accent
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.76, blue: 0.72, alpha: 1),
    ])!.draw(in: path, angle: -60)

    // subtle top highlight (smooth, full height)
    path.addClip()
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.0),
        NSColor.white.withAlphaComponent(0.16),
    ])!.draw(in: rect, angle: 90)

    // white key symbol
    if let sym = whiteSymbol("key.radiowaves.forward.fill", points: s * 0.40) {
        let symRect = NSRect(
            x: (s - sym.size.width) / 2,
            y: (s - sym.size.height) / 2,
            width: sym.size.width, height: sym.size.height)
        sym.draw(in: symRect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let dir = "AppIcon.iconset"
try? fm.removeItem(atPath: dir)
try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

let entries: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for e in entries {
    let rep = renderIcon(e.px)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(dir)/\(e.name).png"))
}
print("Wrote \(entries.count) images to \(dir)/")
