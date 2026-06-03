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

private func drawAccentFrame(size: CGFloat) {
    let outer = rounded(rect(112, 112, 800, 800, size), scaled(142, size))
    let inner = rounded(rect(150, 150, 724, 724, size), scaled(112, size))
    let frame = NSBezierPath()
    frame.append(outer)
    frame.append(inner)
    frame.windingRule = .evenOdd

    NSGraphicsContext.saveGraphicsState()
    frame.addClip()
    NSGradient(colors: [
        NSColor(hex: 0xff4f7b),
        NSColor(hex: 0xff7a3d),
        NSColor(hex: 0xffd166),
    ])?.draw(in: outer.bounds, angle: 132)
    NSGraphicsContext.restoreGraphicsState()

    stroke(outer, NSColor.white.withAlphaComponent(0.16), max(1, scaled(4, size)))
    stroke(inner, NSColor.black.withAlphaComponent(0.56), max(1, scaled(6, size)))
}

private func drawTile(size: CGFloat) {
    let tile = rounded(rect(64, 64, 896, 896, size), scaled(206, size))

    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -scaled(24, size))
    shadow.shadowBlurRadius = scaled(46, size)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.44)
    shadow.set()
    NSGradient(colors: [
        NSColor(hex: 0x221118),
        NSColor(hex: 0x160c10),
        NSColor(hex: 0x0a0608),
    ])?.draw(in: tile, angle: 90)
    NSShadow().set()

    stroke(tile, NSColor.black.withAlphaComponent(0.48), max(1, scaled(8, size)))
    stroke(tile, NSColor.white.withAlphaComponent(0.11), max(1, scaled(5, size)))

    drawAccentFrame(size: size)

    let innerGlow = rounded(rect(176, 176, 672, 672, size), scaled(88, size))
    NSColor(hex: 0xff5a4f, alpha: 0.05).setFill()
    innerGlow.fill()
}

private func iconFont(size: CGFloat, text: String) -> NSFont {
    let baseSize: CGFloat = text == "S" ? 600 : 392
    let pointSize = scaled(baseSize, size)
    return NSFont(name: "HelveticaNeue-Bold", size: pointSize)
        ?? NSFont.systemFont(ofSize: pointSize, weight: .heavy)
}

private func drawCenteredText(_ text: String, size: CGFloat, color: NSColor, offsetY: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: iconFont(size: size, text: text),
        .foregroundColor: color,
        .kern: 0,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let bounds = attributed.boundingRect(
        with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let point = NSPoint(
        x: (size - bounds.width) / 2 - bounds.origin.x,
        y: (size - bounds.height) / 2 - bounds.origin.y + scaled(offsetY, size)
    )
    attributed.draw(at: point)
}

private func drawMonogram(size: CGFloat) {
    let label = size <= 32 ? "S" : "So"

    drawCenteredText(
        label,
        size: size,
        color: NSColor.black.withAlphaComponent(0.35),
        offsetY: label == "S" ? -28 : -24
    )
    drawCenteredText(
        label,
        size: size,
        color: NSColor(hex: 0xff7a3d),
        offsetY: label == "S" ? -18 : -14
    )

    if size >= 128 {
        let underline = rounded(rect(354, 308, 316, 28, size), scaled(14, size))
        NSGradient(colors: [
            NSColor(hex: 0xffd166, alpha: 0.94),
            NSColor(hex: 0xff4f7b, alpha: 0.94),
        ])?.draw(in: underline, angle: 0)
    }
}

private func drawIcon(size: CGFloat) {
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    drawTile(size: size)
    drawMonogram(size: size)
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
