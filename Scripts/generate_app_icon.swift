#!/usr/bin/env swift
import AppKit
import Foundation

private let outputDirectory = URL(fileURLWithPath: "Soma/Assets.xcassets/AppIcon.appiconset")

private struct IconImage {
    let filename: String
    let size: String
    let scale: String
    let pixels: Int
}

private let iconImages: [IconImage] = [
    IconImage(filename: "AppIcon-16.png", size: "16x16", scale: "1x", pixels: 16),
    IconImage(filename: "AppIcon-16@2x.png", size: "16x16", scale: "2x", pixels: 32),
    IconImage(filename: "AppIcon-32.png", size: "32x32", scale: "1x", pixels: 32),
    IconImage(filename: "AppIcon-32@2x.png", size: "32x32", scale: "2x", pixels: 64),
    IconImage(filename: "AppIcon-128.png", size: "128x128", scale: "1x", pixels: 128),
    IconImage(filename: "AppIcon-128@2x.png", size: "128x128", scale: "2x", pixels: 256),
    IconImage(filename: "AppIcon-256.png", size: "256x256", scale: "1x", pixels: 256),
    IconImage(filename: "AppIcon-256@2x.png", size: "256x256", scale: "2x", pixels: 512),
    IconImage(filename: "AppIcon-512.png", size: "512x512", scale: "1x", pixels: 512),
    IconImage(filename: "AppIcon-512@2x.png", size: "512x512", scale: "2x", pixels: 1024),
]

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private func scaled(_ value: CGFloat, for size: CGFloat) -> CGFloat {
    value * size / 1024
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, size: CGFloat) -> NSRect {
    NSRect(x: scaled(x, for: size), y: scaled(y, for: size), width: scaled(width, for: size), height: scaled(height, for: size))
}

private func point(_ x: CGFloat, _ y: CGFloat, size: CGFloat) -> NSPoint {
    NSPoint(x: scaled(x, for: size), y: scaled(y, for: size))
}

private func roundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

private func strokePath(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

private func fillRoundedRect(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    roundedPath(rect, radius: radius).fill()
}

private func drawLine(from start: NSPoint, to end: NSPoint, color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    strokePath(path, color: color, width: width)
}

private func drawCircle(center: NSPoint, radius: CGFloat, fill: NSColor, stroke: NSColor, strokeWidth: CGFloat) {
    let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    fill.setFill()
    circle.fill()
    strokePath(circle, color: stroke, width: strokeWidth)
}

private func drawSpark(center: NSPoint, radius: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x, y: center.y + radius))
    path.curve(
        to: NSPoint(x: center.x + radius, y: center.y),
        controlPoint1: NSPoint(x: center.x + radius * 0.18, y: center.y + radius * 0.38),
        controlPoint2: NSPoint(x: center.x + radius * 0.42, y: center.y + radius * 0.18)
    )
    path.curve(
        to: NSPoint(x: center.x, y: center.y - radius),
        controlPoint1: NSPoint(x: center.x + radius * 0.42, y: center.y - radius * 0.18),
        controlPoint2: NSPoint(x: center.x + radius * 0.18, y: center.y - radius * 0.38)
    )
    path.curve(
        to: NSPoint(x: center.x - radius, y: center.y),
        controlPoint1: NSPoint(x: center.x - radius * 0.18, y: center.y - radius * 0.38),
        controlPoint2: NSPoint(x: center.x - radius * 0.42, y: center.y - radius * 0.18)
    )
    path.curve(
        to: NSPoint(x: center.x, y: center.y + radius),
        controlPoint1: NSPoint(x: center.x - radius * 0.42, y: center.y + radius * 0.18),
        controlPoint2: NSPoint(x: center.x - radius * 0.18, y: center.y + radius * 0.38)
    )
    path.close()
    color.setFill()
    path.fill()
}

private func drawDocumentPath(in documentRect: NSRect, fold: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let radius: CGFloat = documentRect.width * 0.105
    let minX = documentRect.minX
    let minY = documentRect.minY
    let maxX = documentRect.maxX
    let maxY = documentRect.maxY
    path.move(to: NSPoint(x: minX + radius, y: minY))
    path.line(to: NSPoint(x: maxX - radius, y: minY))
    path.curve(to: NSPoint(x: maxX, y: minY + radius), controlPoint1: NSPoint(x: maxX - radius * 0.45, y: minY), controlPoint2: NSPoint(x: maxX, y: minY + radius * 0.45))
    path.line(to: NSPoint(x: maxX, y: maxY - fold))
    path.line(to: NSPoint(x: maxX - fold, y: maxY))
    path.line(to: NSPoint(x: minX + radius, y: maxY))
    path.curve(to: NSPoint(x: minX, y: maxY - radius), controlPoint1: NSPoint(x: minX + radius * 0.45, y: maxY), controlPoint2: NSPoint(x: minX, y: maxY - radius * 0.45))
    path.line(to: NSPoint(x: minX, y: minY + radius))
    path.curve(to: NSPoint(x: minX + radius, y: minY), controlPoint1: NSPoint(x: minX, y: minY + radius * 0.45), controlPoint2: NSPoint(x: minX + radius * 0.45, y: minY))
    path.close()
    return path
}

private func drawIcon(size: CGFloat) {
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let backgroundRect = rect(64, 64, 896, 896, size: size)
    let backgroundRadius = scaled(208, for: size)
    let backgroundPath = roundedPath(backgroundRect, radius: backgroundRadius)

    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -scaled(24, for: size))
    shadow.shadowBlurRadius = scaled(48, for: size)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
    shadow.set()

    NSGradient(colors: [
        NSColor(hex: 0x242b36),
        NSColor(hex: 0x151b24),
        NSColor(hex: 0x0c1118),
    ])?.draw(in: backgroundPath, angle: 90)
    NSShadow().set()

    strokePath(backgroundPath, color: NSColor.white.withAlphaComponent(0.10), width: max(1, scaled(5, for: size)))
    let innerPath = roundedPath(backgroundRect.insetBy(dx: scaled(18, for: size), dy: scaled(18, for: size)), radius: backgroundRadius - scaled(18, for: size))
    strokePath(innerPath, color: NSColor(hex: 0x05070b).withAlphaComponent(0.55), width: max(1, scaled(3, for: size)))

    let center = point(512, 508, size: size)
    let ringRadius = scaled(330, for: size)
    let ringWidth = max(1.25, scaled(17, for: size))
    let ringA = NSBezierPath()
    ringA.appendArc(withCenter: center, radius: ringRadius, startAngle: 138, endAngle: 338, clockwise: false)
    strokePath(ringA, color: NSColor(hex: 0x2f87ff).withAlphaComponent(0.92), width: ringWidth)
    let ringB = NSBezierPath()
    ringB.appendArc(withCenter: center, radius: ringRadius, startAngle: -24, endAngle: 146, clockwise: false)
    strokePath(ringB, color: NSColor(hex: 0x38e1db).withAlphaComponent(0.90), width: ringWidth)

    drawLine(from: point(218, 506, size: size), to: point(806, 506, size: size), color: NSColor(hex: 0x2fa2ff).withAlphaComponent(0.50), width: max(1, scaled(8, for: size)))
    drawLine(from: point(300, 664, size: size), to: point(420, 548, size: size), color: NSColor(hex: 0x4ea0ff).withAlphaComponent(0.58), width: max(1, scaled(8, for: size)))
    drawLine(from: point(724, 664, size: size), to: point(608, 548, size: size), color: NSColor(hex: 0x40ddd8).withAlphaComponent(0.58), width: max(1, scaled(8, for: size)))

    let shouldDrawDetails = size >= 96
    let shouldDrawNodeDetails = size >= 192
    let nodeFill = NSColor(hex: 0x101722)
    let nodeStrokeBlue = NSColor(hex: 0x5597ff)
    let nodeStrokeTeal = NSColor(hex: 0x43ded8)
    let nodeStrokeViolet = NSColor(hex: 0x805cff)
    let nodeRadius = scaled(76, for: size)
    let nodeWidth = max(1.2, scaled(10, for: size))

    let topLeft = point(292, 696, size: size)
    let topRight = point(760, 690, size: size)
    let bottomLeft = point(292, 326, size: size)
    let bottomRight = point(760, 326, size: size)

    drawCircle(center: topLeft, radius: nodeRadius, fill: nodeFill, stroke: nodeStrokeBlue, strokeWidth: nodeWidth)
    drawCircle(center: topRight, radius: nodeRadius, fill: nodeFill, stroke: nodeStrokeTeal, strokeWidth: nodeWidth)
    drawCircle(center: bottomLeft, radius: nodeRadius, fill: nodeFill, stroke: nodeStrokeViolet, strokeWidth: nodeWidth)
    drawCircle(center: bottomRight, radius: nodeRadius, fill: nodeFill, stroke: nodeStrokeTeal, strokeWidth: nodeWidth)

    if shouldDrawNodeDetails {
        let miniWidth = scaled(8, for: size)
        drawLine(from: point(264, 712, size: size), to: point(338, 712, size: size), color: nodeStrokeBlue, width: miniWidth)
        drawLine(from: point(264, 684, size: size), to: point(338, 684, size: size), color: nodeStrokeBlue.withAlphaComponent(0.85), width: miniWidth)
        drawLine(from: point(264, 656, size: size), to: point(316, 656, size: size), color: nodeStrokeBlue.withAlphaComponent(0.72), width: miniWidth)

        drawLine(from: point(724, 698, size: size), to: point(762, 720, size: size), color: nodeStrokeTeal, width: miniWidth)
        drawLine(from: point(724, 698, size: size), to: point(762, 670, size: size), color: nodeStrokeTeal, width: miniWidth)
        drawCircle(center: point(724, 698, size: size), radius: scaled(14, for: size), fill: nodeStrokeTeal, stroke: nodeStrokeTeal, strokeWidth: 0)
        drawCircle(center: point(762, 720, size: size), radius: scaled(14, for: size), fill: nodeStrokeTeal, stroke: nodeStrokeTeal, strokeWidth: 0)
        drawCircle(center: point(762, 670, size: size), radius: scaled(14, for: size), fill: nodeStrokeTeal, stroke: nodeStrokeTeal, strokeWidth: 0)

        drawLine(from: point(274, 326, size: size), to: point(310, 326, size: size), color: nodeStrokeViolet, width: miniWidth)
        drawLine(from: point(760, 326, size: size), to: point(796, 326, size: size), color: nodeStrokeTeal, width: miniWidth)
        drawLine(from: point(735, 352, size: size), to: point(762, 326, size: size), color: nodeStrokeTeal, width: miniWidth)
        drawLine(from: point(735, 300, size: size), to: point(762, 326, size: size), color: nodeStrokeTeal, width: miniWidth)
    }

    let documentBack = drawDocumentPath(in: rect(382, 356, 310, 388, size: size), fold: scaled(78, for: size))
    NSColor(hex: 0x323b49).withAlphaComponent(0.88).setFill()
    documentBack.fill()
    strokePath(documentBack, color: NSColor.white.withAlphaComponent(0.18), width: max(1, scaled(5, for: size)))

    let documentRect = rect(336, 350, 338, 404, size: size)
    let fold = scaled(92, for: size)
    let documentPath = drawDocumentPath(in: documentRect, fold: fold)
    let documentShadow = NSShadow()
    documentShadow.shadowOffset = NSSize(width: 0, height: -scaled(10, for: size))
    documentShadow.shadowBlurRadius = scaled(28, for: size)
    documentShadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
    documentShadow.set()
    NSGradient(colors: [
        NSColor(hex: 0x3a4453),
        NSColor(hex: 0x1f2732),
    ])?.draw(in: documentPath, angle: 90)
    NSShadow().set()
    strokePath(documentPath, color: NSColor.white.withAlphaComponent(0.25), width: max(1, scaled(5, for: size)))

    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: documentRect.maxX - fold, y: documentRect.maxY))
    foldPath.line(to: NSPoint(x: documentRect.maxX, y: documentRect.maxY - fold))
    foldPath.line(to: NSPoint(x: documentRect.maxX - fold, y: documentRect.maxY - fold))
    foldPath.close()
    NSGradient(colors: [
        NSColor(hex: 0x5ec7ff),
        NSColor(hex: 0x3268ff),
    ])?.draw(in: foldPath, angle: -45)

    let pocketRect = rect(300, 246, 424, 300, size: size)
    let pocketPath = roundedPath(pocketRect, radius: scaled(58, for: size))
    let pocketShadow = NSShadow()
    pocketShadow.shadowOffset = NSSize(width: 0, height: -scaled(12, for: size))
    pocketShadow.shadowBlurRadius = scaled(32, for: size)
    pocketShadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
    pocketShadow.set()
    NSGradient(colors: [
        NSColor(hex: 0x1a222c),
        NSColor(hex: 0x121820),
    ])?.draw(in: pocketPath, angle: 90)
    NSShadow().set()
    strokePath(pocketPath, color: NSColor.black.withAlphaComponent(0.42), width: max(1, scaled(4, for: size)))

    let pocketLip = NSBezierPath()
    pocketLip.move(to: point(300, 512, size: size))
    pocketLip.curve(to: point(404, 422, size: size), controlPoint1: point(332, 492, size: size), controlPoint2: point(354, 454, size: size))
    pocketLip.line(to: point(620, 422, size: size))
    pocketLip.curve(to: point(724, 512, size: size), controlPoint1: point(670, 454, size: size), controlPoint2: point(692, 492, size: size))
    strokePath(pocketLip, color: NSColor(hex: 0x42e1de), width: max(1.2, scaled(12, for: size)))

    if shouldDrawDetails {
        drawLine(from: point(406, 632, size: size), to: point(578, 632, size: size), color: NSColor(hex: 0x5dbbff), width: max(1, scaled(18, for: size)))
        drawLine(from: point(406, 570, size: size), to: point(604, 570, size: size), color: NSColor(hex: 0x9ba7b8).withAlphaComponent(0.62), width: max(1, scaled(13, for: size)))
        drawLine(from: point(406, 526, size: size), to: point(604, 526, size: size), color: NSColor(hex: 0x9ba7b8).withAlphaComponent(0.52), width: max(1, scaled(13, for: size)))
        drawCircle(center: point(420, 470, size: size), radius: scaled(14, for: size), fill: NSColor(hex: 0x8065ff), stroke: NSColor.white.withAlphaComponent(0.18), strokeWidth: max(0.5, scaled(2, for: size)))
        drawCircle(center: point(468, 470, size: size), radius: scaled(14, for: size), fill: NSColor(hex: 0x40ddd8), stroke: NSColor.white.withAlphaComponent(0.18), strokeWidth: max(0.5, scaled(2, for: size)))
    }

    drawSpark(center: point(512, 324, size: size), radius: scaled(size >= 96 ? 54 : 62, for: size), color: NSColor(hex: 0x705dff))
    if shouldDrawDetails {
        drawLine(from: point(452, 356, size: size), to: point(432, 376, size: size), color: NSColor(hex: 0x5dbbff), width: max(1, scaled(8, for: size)))
        drawLine(from: point(572, 356, size: size), to: point(592, 376, size: size), color: NSColor(hex: 0x5dbbff), width: max(1, scaled(8, for: size)))
        drawLine(from: point(452, 292, size: size), to: point(432, 272, size: size), color: NSColor(hex: 0x5dbbff), width: max(1, scaled(8, for: size)))
        drawLine(from: point(572, 292, size: size), to: point(592, 272, size: size), color: NSColor(hex: 0x5dbbff), width: max(1, scaled(8, for: size)))
    }
}

private func writeIcon(_ icon: IconImage) throws {
    let pixels = icon.pixels
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "SomaIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap rep"])
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SomaIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: outputDirectory.appendingPathComponent(icon.filename), options: .atomic)
}

private func writeContents() throws {
    let images = iconImages.map { icon -> [String: String] in
        [
            "filename": icon.filename,
            "idiom": "mac",
            "scale": icon.scale,
            "size": icon.size,
        ]
    }
    let payload: [String: Any] = [
        "images": images,
        "info": [
            "author": "xcode",
            "version": 1,
        ],
    ]
    var data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0a)
    try data.write(to: outputDirectory.appendingPathComponent("Contents.json"), options: .atomic)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for icon in iconImages {
    try writeIcon(icon)
}
try writeContents()
print("Generated \(iconImages.count) Soma app icon images in \(outputDirectory.path)")
