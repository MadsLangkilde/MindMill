// Draws the Mindmill app icon from the pixel-art logo and writes an .iconset folder for iconutil.
// Usage: make-icon <logo.png> <out.iconset>
import AppKit

let logo = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let tileTop = NSColor(srgbRed: 1.00, green: 0.97, blue: 0.93, alpha: 1)
let tileBottom = NSColor(srgbRed: 0.96, green: 0.90, blue: 0.84, alpha: 1)

func draw(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [tileTop, tileBottom])!.draw(in: path, angle: -90)
    // The logo is pixel art: keep hard pixel edges when scaling up, smooth only when shrinking.
    let side = 704 * s
    ctx.imageInterpolation = side >= logo.size.width ? .none : .high
    logo.draw(in: NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(CGFloat(base * scale)).write(to: out.appendingPathComponent(name))
    }
}
