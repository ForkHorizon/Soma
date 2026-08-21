#!/usr/bin/env swift
import AppKit
import Foundation

private let args = CommandLine.arguments.dropFirst()
private let sourceURL = URL(fileURLWithPath: args.first ?? "SomaIcon.png")
private let outputDirectory = URL(fileURLWithPath: args.dropFirst().first ?? "Soma/Assets.xcassets/AppIcon.appiconset")

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

private func render(_ image: NSImage, pixels: Int) throws -> Data {
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
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SomaIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    return png
}

private func writeIcon(_ icon: IconImage, from source: NSImage) throws {
    let png = try render(source, pixels: icon.pixels)
    try png.write(to: outputDirectory.appendingPathComponent(icon.filename), options: .atomic)
}

private func writeContents() throws {
    let images = iconImages.map { ["filename": $0.filename, "idiom": "mac", "scale": $0.scale, "size": $0.size] }
    let payload: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    var data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0a)
    try data.write(to: outputDirectory.appendingPathComponent("Contents.json"), options: .atomic)
}

guard let source = NSImage(contentsOf: sourceURL) else {
    throw NSError(domain: "SomaIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not read \(sourceURL.path)"])
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for icon in iconImages {
    try writeIcon(icon, from: source)
}
try writeContents()
print("Generated \(iconImages.count) app icon images from \(sourceURL.path)")
