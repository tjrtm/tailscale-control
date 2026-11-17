// Draws the Tailscale Control app icon (an original design: rounded square, gradient, abstract routing glyph)
// with CoreGraphics and writes the PNG files of an .iconset folder.
//
//   swiftc scripts/make-icon.swift -o build/make-icon && build/make-icon build/icon/AppIcon.iconset
//   iconutil -c icns build/icon/AppIcon.iconset -o build/icon/AppIcon.icns
//
// scripts/build.sh does this automatically. An optional second argument renders a single PNG of that pixel size
// instead (`build/make-icon preview.png 512`), which is handy while tweaking the design.
import CoreGraphics
import Foundation
import ImageIO

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ colors: [CGColor], at locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

/// Draws the icon on a 1024 x 1024 canvas (origin bottom-left).
func drawIcon(_ ctx: CGContext) {
    // macOS icon grid: the artwork fills 824 x 824 of the 1024 canvas, leaving room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
    ctx.setFillColor(rgb(0x1B2A6B))
    ctx.addPath(shape)
    ctx.fillPath()
    ctx.restoreGState()

    // Everything else is clipped to the rounded square.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Base gradient: teal at the top left to deep indigo at the bottom right.
    ctx.drawLinearGradient(gradient([rgb(0x2FC4CF), rgb(0x3A74E0), rgb(0x3A2FB3)], at: [0, 0.55, 1]),
                           start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Gentle light from the top.
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 40), options: [])

    // Faint concentric rings behind the glyph, like radar / signal range.
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.07))
    ctx.setLineWidth(6)
    for radius in [210.0, 320.0, 430.0] {
        ctx.strokeEllipse(in: CGRect(x: 512 - radius, y: 512 - radius, width: radius * 2, height: radius * 2))
    }

    drawGlyph(ctx)
    ctx.restoreGState()

    // Thin inner edge for definition.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

/// A hub with four routes ending in nodes; one route is highlighted (the "active" path).
func drawGlyph(_ ctx: CGContext) {
    let hub = CGPoint(x: 512, y: 500)
    let nodes: [(point: CGPoint, radius: CGFloat, c1: CGPoint, c2: CGPoint, active: Bool)] = [
        (CGPoint(x: 276, y: 668), 46, CGPoint(x: 420, y: 520), CGPoint(x: 330, y: 560), false),   // upper left
        (CGPoint(x: 760, y: 700), 58, CGPoint(x: 600, y: 520), CGPoint(x: 700, y: 560), true),    // upper right (active route)
        (CGPoint(x: 748, y: 338), 46, CGPoint(x: 600, y: 480), CGPoint(x: 700, y: 420), false),   // lower right
        (CGPoint(x: 300, y: 330), 40, CGPoint(x: 430, y: 470), CGPoint(x: 350, y: 420), false),   // lower left
    ]

    ctx.setLineCap(.round)
    for node in nodes {
        let path = CGMutablePath()
        path.move(to: hub)
        path.addCurve(to: node.point, control1: node.c1, control2: node.c2)
        ctx.saveGState()
        if node.active {
            // Glow under the highlighted route.
            ctx.setShadow(offset: .zero, blur: 26, color: rgb(0xFFFFFF, 0.65))
            ctx.setStrokeColor(rgb(0xFFFFFF))
            ctx.setLineWidth(30)
        } else {
            ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
            ctx.setLineWidth(22)
        }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Nodes: white discs with a gradient core, so they read as ports.
    for node in nodes {
        let r = node.radius
        let rect = CGRect(x: node.point.x - r, y: node.point.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x0B1650, 0.4))
        ctx.setFillColor(rgb(0xFFFFFF, node.active ? 1 : 0.92))
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        let core = rect.insetBy(dx: r * 0.42, dy: r * 0.42)
        ctx.saveGState()
        ctx.addEllipse(in: core)
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(node.active ? 0x2FC4CF : 0x3A74E0), rgb(0x3A2FB3)]),
                               start: CGPoint(x: core.minX, y: core.maxY), end: CGPoint(x: core.maxX, y: core.minY), options: [])
        ctx.restoreGState()
    }

    // Hub: larger disc with a ring.
    let hubRect = CGRect(x: hub.x - 88, y: hub.y - 88, width: 176, height: 176)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: rgb(0x0B1650, 0.45))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: hubRect)
    ctx.restoreGState()
    let ring = hubRect.insetBy(dx: 30, dy: 30)
    ctx.saveGState()
    ctx.addEllipse(in: ring)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x2FC4CF), rgb(0x3A2FB3)]),
                           start: CGPoint(x: ring.minX, y: ring.maxY), end: CGPoint(x: ring.maxX, y: ring.minY), options: [])
    ctx.restoreGState()
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: ring.insetBy(dx: 26, dy: 26))
}

func png(size: Int) -> Data? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)
    guard let image = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

// MARK: - main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <AppIcon.iconset directory> | make-icon <file.png> <pixels>\n".utf8))
    exit(2)
}

if arguments.count >= 3, let pixels = Int(arguments[2]) {
    guard let data = png(size: pixels) else { print("rendering failed"); exit(1) }
    try data.write(to: URL(fileURLWithPath: arguments[1]))
    exit(0)
}

let directory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let files: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for file in files {
    guard let data = png(size: file.pixels) else { print("rendering \(file.name) failed"); exit(1) }
    try data.write(to: directory.appendingPathComponent(file.name))
}
