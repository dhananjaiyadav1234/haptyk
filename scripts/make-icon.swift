// Draws the Thock app icon (a keycap) and writes an .iconset directory: swift make-icon.swift <out.iconset>
import AppKit

func draw(size s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        let inset = s * 0.06
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: s * 0.22, yRadius: s * 0.22)
        NSGradient(colors: [NSColor(red: 0.20, green: 0.22, blue: 0.30, alpha: 1), NSColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1)])!
            .draw(in: tile, angle: -90)
        // keycap base
        let capRect = NSRect(x: s * 0.2, y: s * 0.2, width: s * 0.6, height: s * 0.6)
        let base = NSBezierPath(roundedRect: capRect, xRadius: s * 0.1, yRadius: s * 0.1)
        NSColor(red: 0.55, green: 0.60, blue: 0.72, alpha: 1).setFill(); base.fill()
        let top = NSBezierPath(roundedRect: capRect.insetBy(dx: s * 0.045, dy: s * 0.045).offsetBy(dx: 0, dy: s * 0.025), xRadius: s * 0.075, yRadius: s * 0.075)
        NSGradient(colors: [NSColor(red: 0.97, green: 0.97, blue: 1.0, alpha: 1), NSColor(red: 0.82, green: 0.86, blue: 0.95, alpha: 1)])!
            .draw(in: top, angle: -90)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: s * 0.30, weight: .heavy),
            .foregroundColor: NSColor(red: 0.16, green: 0.18, blue: 0.27, alpha: 1)]
        let str = NSAttributedString(string: "T", attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: capRect.midX - sz.width / 2, y: capRect.midY - sz.height / 2 + s * 0.02))
        return true
    }
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
