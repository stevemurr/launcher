// Generates the Launcher app icon as a .iconset directory.
// Usage: swift Scripts/generate-icon.swift <output.iconset>
// Then: iconutil -c icns <output.iconset> -o Resources/AppIcon.icns

import CoreGraphics
import Foundation
import ImageIO

func drawIcon(pixels: Int) -> CGImage? {
    let s = CGFloat(pixels) / 1024.0
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil,
              width: pixels,
              height: pixels,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt squircle centered on a 1024pt canvas.
    let squircle = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 186,
        cornerHeight: 186,
        transform: nil
    )
    ctx.addPath(squircle)
    ctx.clip()

    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.447, green: 0.427, blue: 0.984, alpha: 1),
            CGColor(red: 0.271, green: 0.216, blue: 0.816, alpha: 1),
            CGColor(red: 0.153, green: 0.110, blue: 0.478, alpha: 1),
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(
        background,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )

    let glow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 512, y: 900),
        startRadius: 0,
        endCenter: CGPoint(x: 512, y: 900),
        endRadius: 620,
        options: []
    )

    // Shadow parameters live in device space, so scale them by hand.
    ctx.setShadow(
        offset: CGSize(width: 0, height: -14 * s),
        blur: 36 * s,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
    )

    let lensCenter = CGPoint(x: 468, y: 578)
    let lensRadius: CGFloat = 196
    let lensRect = CGRect(
        x: lensCenter.x - lensRadius,
        y: lensCenter.y - lensRadius,
        width: lensRadius * 2,
        height: lensRadius * 2
    )

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.fillEllipse(in: lensRect)

    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineWidth(92)
    ctx.strokeEllipse(in: lensRect)

    ctx.setLineWidth(100)
    ctx.move(to: CGPoint(x: 616, y: 430))
    ctx.addLine(to: CGPoint(x: 778, y: 268))
    ctx.strokePath()

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Cannot create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Failed to write \(url.path)")
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/generate-icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
    guard let image = drawIcon(pixels: entry.pixels) else {
        fatalError("Failed to render \(entry.name)")
    }
    writePNG(image, to: outputDir.appendingPathComponent("\(entry.name).png"))
}
