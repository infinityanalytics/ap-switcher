#!/usr/bin/env swift
import Foundation
import AppKit

func ensureDir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: url, options: .atomic)
}

func makeIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    defer { img.unlockFocus() }

    // Background
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.95, alpha: 1.0).setFill()
    let radius = s * 0.22
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

    // SF Symbol: wifi
    let base = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil) ?? NSImage()
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.58, weight: .semibold)
    let configured = base.withSymbolConfiguration(config) ?? base
    configured.isTemplate = true
    let symbol = configured

    let symbolSize = s * 0.78
    let symbolRect = NSRect(
        x: (s - symbolSize) / 2,
        y: (s - symbolSize) / 2,
        width: symbolSize,
        height: symbolSize
    )
    NSColor.white.set()
    symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

    return img
}

let args = CommandLine.arguments
guard args.count == 2 else {
    fputs("Usage: generate-icon.swift <output.iconset-dir>\n", stderr)
    exit(2)
}

let iconsetPath = args[1]
do {
    try ensureDir(iconsetPath)

    let outputs: [(Int, String)] = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png")
    ]

    for (size, name) in outputs {
        let img = makeIcon(size: size)
        try writePNG(img, to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(name))
    }
} catch {
    fputs("Icon generation failed: \(error)\n", stderr)
    exit(1)
}

