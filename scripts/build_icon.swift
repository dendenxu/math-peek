#!/usr/bin/env swift
import AppKit

// Keep the geometry and colors in sync with the editable assets/icon.svg.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets", isDirectory: true)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("math-peek-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = temporary.appendingPathComponent("MathPeek.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func gradient(_ context: CGContext, colors: [CGColor], locations: [CGFloat], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func render(size: Int) throws -> Data {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: image)!.cgContext
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    context.setShouldAntialias(true)

    let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 196, cornerHeight: 196, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, alpha: 0.28))
    context.addPath(tile)
    context.setFillColor(color(0x1b1e24))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tile)
    context.clip()
    gradient(context, colors: [color(0x33373e), color(0x1b1e24), color(0x111318)], locations: [0, 0.5, 1],
             from: CGPoint(x: 64, y: 64), to: CGPoint(x: 960, y: 960))
    context.restoreGState()

    context.saveGState()
    context.addPath(CGPath(roundedRect: CGRect(x: 66, y: 66, width: 892, height: 892), cornerWidth: 194, cornerHeight: 194, transform: nil))
    context.setLineWidth(3)
    context.replacePathWithStrokedPath()
    context.clip()
    gradient(context, colors: [color(0xffffff, alpha: 0.28), color(0xffffff, alpha: 0.04), color(0xffffff, alpha: 0.10)], locations: [0, 0.48, 1],
             from: CGPoint(x: 0, y: 66), to: CGPoint(x: 0, y: 958))
    context.restoreGState()

    let sigma = CGMutablePath()
    let vertices: [CGPoint] = [
        CGPoint(x: 264, y: 250), CGPoint(x: 672, y: 250), CGPoint(x: 672, y: 334),
        CGPoint(x: 391, y: 334), CGPoint(x: 563, y: 508), CGPoint(x: 391, y: 690),
        CGPoint(x: 672, y: 690), CGPoint(x: 672, y: 774), CGPoint(x: 264, y: 774),
        CGPoint(x: 264, y: 699), CGPoint(x: 446, y: 509), CGPoint(x: 264, y: 326)
    ]
    sigma.addLines(between: vertices)
    sigma.closeSubpath()
    context.saveGState()
    context.addPath(sigma)
    context.clip()
    gradient(context, colors: [color(0xffffff), color(0xd5d9e0)], locations: [0, 1],
             from: CGPoint(x: 0, y: 250), to: CGPoint(x: 0, y: 774))
    context.restoreGState()
    context.addPath(CGPath(roundedRect: CGRect(x: 712, y: 718, width: 96, height: 56), cornerWidth: 8, cornerHeight: 8, transform: nil))
    context.setFillColor(color(0xd5d9e0))
    context.fillPath()
    return image.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let png = try render(size: points * scale)
        try png.write(to: iconset.appendingPathComponent(name))
        if points == 512 && scale == 2 {
            try png.write(to: assets.appendingPathComponent("icon.png"))
        }
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("MathPeek.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Built assets/icon.png and assets/MathPeek.icns")
