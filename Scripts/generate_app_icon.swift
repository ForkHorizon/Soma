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

private let iconImages = [
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
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private func scaled(_ value: CGFloat, _ size: CGFloat) -> CGFloat { value * size / 1024 }

private func point(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> NSPoint {
    NSPoint(x: scaled(x, size), y: scaled(y, size))
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ size: CGFloat) -> NSRect {
    NSRect(x: scaled(x, size), y: scaled(y, size), width: scaled(width, size), height: scaled(height, size))
}

private func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

private func stroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

private func line(_ start: NSPoint, _ end: NSPoint, _ color: NSColor, _ width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    stroke(path, color, width)
}

private func circle(_ center: NSPoint, _ radius: CGFloat, fill: NSColor, stroke strokeColor: NSColor, width: CGFloat) {
    let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    fill.setFill()
    path.fill()
    stroke(path, strokeColor, width)
}

private func documentPath(_ documentRect: NSRect, fold: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let radius = documentRect.width * 0.105
    path.move(to: NSPoint(x: documentRect.minX + radius, y: documentRect.minY))
    path.line(to: NSPoint(x: documentRect.maxX - radius, y: documentRect.minY))
    path.curve(to: NSPoint(x: documentRect.maxX, y: documentRect.minY + radius), controlPoint1: NSPoint(x: documentRect.maxX - radius * 0.45, y: documentRect.minY), controlPoint2: NSPoint(x: documentRect.maxX, y: documentRect.minY + radius * 0.45))
    path.line(to: NSPoint(x: documentRect.maxX, y: documentRect.maxY - fold))
    path.line(to: NSPoint(x: documentRect.maxX - fold, y: documentRect.maxY))
    path.line(to: NSPoint(x: documentRect.minX + radius, y: documentRect.maxY))
    path.curve(to: NSPoint(x: documentRect.minX, y: documentRect.maxY - radius), controlPoint1: NSPoint(x: documentRect.minX + radius * 0.45, y: documentRect.maxY), controlPoint2: NSPoint(x: documentRect.minX, y: documentRect.maxY - radius * 0.45))
    path.line(to: NSPoint(x: documentRect.minX, y: documentRect.minY + radius))
    path.curve(to: NSPoint(x: documentRect.minX + radius, y: documentRect.minY), controlPoint1: NSPoint(x: documentRect.minX, y: documentRect.minY + radius * 0.45), controlPoint2: NSPoint(x: documentRect.minX + radius * 0.45, y: documentRect.minY))
    path.close()
    return path
}

private func drawBackground(size: CGFloat) -> NSBezierPath {
    let backgroundRect = rect(64, 64, 896, 896, size)
    let backgroundPath = rounded(backgroundRect, scaled(208, size))
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -scaled(24, size))
    shadow.shadowBlurRadius = scaled(48, size)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
    shadow.set()
    NSGradient(colors: [NSColor(hex: 0x242b36), NSColor(hex: 0x151b24), NSColor(hex: 0x0c1118)])?.draw(in: backgroundPath, angle: 90)
    NSShadow().set()
    stroke(backgroundPath, NSColor.white.withAlphaComponent(0.10), max(1, scaled(5, size)))
    return backgroundPath
}

private func drawRings(size: CGFloat) {
    let center = point(512, 508, size)
    let ringRadius = scaled(330, size)
    let ringWidth = max(1.25, scaled(17, size))
    for arc in [(138.0, 338.0, 0x2f87ff), (-24.0, 146.0, 0x38e1db)] {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: ringRadius, startAngle: arc.0, endAngle: arc.1)
        stroke(path, NSColor(hex: UInt32(arc.2)).withAlphaComponent(0.9), ringWidth)
    }
    line(point(218, 506, size), point(806, 506, size), NSColor(hex: 0x2fa2ff).withAlphaComponent(0.5), max(1, scaled(8, size)))
    line(point(300, 664, size), point(420, 548, size), NSColor(hex: 0x4ea0ff).withAlphaComponent(0.58), max(1, scaled(8, size)))
    line(point(724, 664, size), point(608, 548, size), NSColor(hex: 0x40ddd8).withAlphaComponent(0.58), max(1, scaled(8, size)))
}

private func drawNodes(size: CGFloat) {
    let fill = NSColor(hex: 0x101722)
    let radius = scaled(76, size)
    let width = max(1.2, scaled(10, size))
    let nodes = [
        (292.0, 696.0, 0x5597ff),
        (760.0, 690.0, 0x43ded8),
        (292.0, 326.0, 0x805cff),
        (760.0, 326.0, 0x43ded8),
    ]
    for node in nodes {
        circle(point(node.0, node.1, size), radius, fill: fill, stroke: NSColor(hex: UInt32(node.2)), width: width)
    }
}

private func drawDocument(size: CGFloat) {
    let back = documentPath(rect(382, 356, 310, 388, size), fold: scaled(78, size))
    NSColor(hex: 0x323b49).withAlphaComponent(0.88).setFill()
    back.fill()
    stroke(back, NSColor.white.withAlphaComponent(0.18), max(1, scaled(5, size)))
    let documentRect = rect(336, 350, 338, 404, size)
    let fold = scaled(92, size)
    let document = documentPath(documentRect, fold: fold)
    NSGradient(colors: [NSColor(hex: 0x3a4453), NSColor(hex: 0x1f2732)])?.draw(in: document, angle: 90)
    stroke(document, NSColor.white.withAlphaComponent(0.25), max(1, scaled(5, size)))
    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: documentRect.maxX - fold, y: documentRect.maxY))
    foldPath.line(to: NSPoint(x: documentRect.maxX, y: documentRect.maxY - fold))
    foldPath.line(to: NSPoint(x: documentRect.maxX - fold, y: documentRect.maxY - fold))
    foldPath.close()
    NSGradient(colors: [NSColor(hex: 0x5ec7ff), NSColor(hex: 0x3268ff)])?.draw(in: foldPath, angle: -45)
}

private func drawPocket(size: CGFloat) {
    let pocket = rounded(rect(300, 246, 424, 300, size), scaled(58, size))
    NSGradient(colors: [NSColor(hex: 0x1a222c), NSColor(hex: 0x121820)])?.draw(in: pocket, angle: 90)
    stroke(pocket, NSColor.black.withAlphaComponent(0.42), max(1, scaled(4, size)))
    let lip = NSBezierPath()
    lip.move(to: point(300, 512, size))
    lip.curve(to: point(404, 422, size), controlPoint1: point(332, 492, size), controlPoint2: point(354, 454, size))
    lip.line(to: point(620, 422, size))
    lip.curve(to: point(724, 512, size), controlPoint1: point(670, 454, size), controlPoint2: point(692, 492, size))
    stroke(lip, NSColor(hex: 0x42e1de), max(1.2, scaled(12, size)))
}

private func drawSpark(size: CGFloat) {
    let center = point(512, 324, size)
    let radius = scaled(size >= 96 ? 54 : 62, size)
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x, y: center.y + radius))
    path.curve(to: NSPoint(x: center.x + radius, y: center.y), controlPoint1: NSPoint(x: center.x + radius * 0.18, y: center.y + radius * 0.38), controlPoint2: NSPoint(x: center.x + radius * 0.42, y: center.y + radius * 0.18))
    path.curve(to: NSPoint(x: center.x, y: center.y - radius), controlPoint1: NSPoint(x: center.x + radius * 0.42, y: center.y - radius * 0.18), controlPoint2: NSPoint(x: center.x + radius * 0.18, y: center.y - radius * 0.38))
    path.curve(to: NSPoint(x: center.x - radius, y: center.y), controlPoint1: NSPoint(x: center.x - radius * 0.18, y: center.y - radius * 0.38), controlPoint2: NSPoint(x: center.x - radius * 0.42, y: center.y - radius * 0.18))
    path.curve(to: NSPoint(x: center.x, y: center.y + radius), controlPoint1: NSPoint(x: center.x - radius * 0.42, y: center.y + radius * 0.18), controlPoint2: NSPoint(x: center.x - radius * 0.18, y: center.y + radius * 0.38))
    path.close()
    NSColor(hex: 0x705dff).setFill()
    path.fill()
}

private func drawIcon(size: CGFloat) {
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    _ = drawBackground(size: size)
    drawRings(size: size)
    drawNodes(size: size)
    drawDocument(size: size)
    drawPocket(size: size)
    if size >= 96 {
        line(point(406, 632, size), point(578, 632, size), NSColor(hex: 0x5dbbff), max(1, scaled(18, size)))
        line(point(406, 570, size), point(604, 570, size), NSColor(hex: 0x9ba7b8).withAlphaComponent(0.62), max(1, scaled(13, size)))
        circle(point(444, 470, size), scaled(14, size), fill: NSColor(hex: 0x40ddd8), stroke: NSColor.white.withAlphaComponent(0.18), width: max(0.5, scaled(2, size)))
    }
    drawSpark(size: size)
}

private func writeIcon(_ icon: IconImage) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: icon.pixels,
        pixelsHigh: icon.pixels,
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
    rep.size = NSSize(width: icon.pixels, height: icon.pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(size: CGFloat(icon.pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SomaIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: outputDirectory.appendingPathComponent(icon.filename), options: .atomic)
}

private func writeContents() throws {
    let images = iconImages.map { ["filename": $0.filename, "idiom": "mac", "scale": $0.scale, "size": $0.size] }
    let payload: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
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
