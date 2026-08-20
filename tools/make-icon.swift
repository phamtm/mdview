// Draws the app icon. Three variants; `--sheet` also renders Dock-size previews
// so an icon can be judged at the size it is actually seen.
//
//   swift tools/make-icon.swift out.png ink 1024
//   swift tools/make-icon.swift --sheet preview.png paper
import AppKit

enum Variant: String {
    case ink, paper, accent

    var background: [NSColor] {
        switch self {
        case .ink:
            return [NSColor(srgbRed: 0.20, green: 0.21, blue: 0.25, alpha: 1),
                    NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1)]
        case .paper:
            return [NSColor(srgbRed: 0.99, green: 0.985, blue: 0.97, alpha: 1),
                    NSColor(srgbRed: 0.93, green: 0.92, blue: 0.90, alpha: 1)]
        case .accent:
            return [NSColor(srgbRed: 0.35, green: 0.48, blue: 0.95, alpha: 1),
                    NSColor(srgbRed: 0.16, green: 0.27, blue: 0.72, alpha: 1)]
        }
    }

    var mark: NSColor {
        switch self {
        case .paper: return NSColor(srgbRed: 0.11, green: 0.11, blue: 0.10, alpha: 1)
        case .ink, .accent: return NSColor(white: 0.99, alpha: 1)
        }
    }

    /// Paper needs a hairline or it dissolves into a light Dock background.
    var edge: NSColor {
        switch self {
        case .paper: return NSColor(srgbRed: 0.80, green: 0.79, blue: 0.76, alpha: 1)
        case .ink, .accent: return NSColor(white: 1, alpha: 0.16)
        }
    }
}

func drawIcon(_ variant: Variant, size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons sit inside a margin rather than filling the canvas.
    let inset = size * 0.085
    let card = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = card.width * 0.235
    let shape = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)

    NSGradient(colors: variant.background)!.draw(in: shape, angle: -90)
    shape.lineWidth = max(size * 0.005, 1)
    variant.edge.setStroke()
    shape.stroke()

    let glyph = "M↓" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.34, weight: .bold),
        .foregroundColor: variant.mark,
        .kern: -size * 0.012,
    ]
    let bounds = glyph.size(withAttributes: attrs)
    glyph.draw(at: NSPoint(x: (size - bounds.width) / 2,
                           y: (size - bounds.height) / 2 - size * 0.012),
               withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

let args = CommandLine.arguments
if args.count > 2, args[1] == "--sheet" {
    let out = args[2]
    let variant = Variant(rawValue: args.count > 3 ? args[3] : "ink") ?? .ink
    let width: CGFloat = 900, height: CGFloat = 520
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    NSColor(white: 0.62, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    func place(_ rep: NSBitmapImageRep, at point: NSPoint, side: CGFloat) {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.draw(in: NSRect(x: point.x, y: point.y, width: side, height: side))
    }
    place(drawIcon(variant, size: 1024), at: NSPoint(x: 40, y: height - 380 - 40), side: 380)

    // Small sizes share a baseline so their relative scale is obvious.
    let baseline: CGFloat = 170
    var x: CGFloat = 470
    for side in [CGFloat(128), 96, 64, 32] {
        place(drawIcon(variant, size: side * 2), at: NSPoint(x: x, y: baseline), side: side)
        x += side + 22
    }
    let label = "\(variant.rawValue)  —  actual Dock sizes: 128, 96, 64, 32" as NSString
    label.draw(at: NSPoint(x: 44, y: 70), withAttributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .medium),
        .foregroundColor: NSColor.white,
    ])
    NSGraphicsContext.restoreGraphicsState()
    try png(sheet).write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
} else {
    let out = args.count > 1 ? args[1] : "icon.png"
    let variant = Variant(rawValue: args.count > 2 ? args[2] : "ink") ?? .ink
    let size = args.count > 3 ? CGFloat(Double(args[3]) ?? 1024) : 1024
    try png(drawIcon(variant, size: size)).write(to: URL(fileURLWithPath: out))
    print("wrote \(out) (\(variant.rawValue), \(Int(size))px)")
}
