#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: make-icon.swift <output.icns>\n", stderr)
    exit(1)
}

let outputICNS = URL(fileURLWithPath: CommandLine.arguments[1])
let tempIconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("RelayIDE-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: tempIconset, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixelSize)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    // Bauhaus Warm Sandpaper outer squircle
    let pad = s * 0.08
    let card = rect.insetBy(dx: pad, dy: pad)
    let bgPath = NSBezierPath(roundedRect: card, xRadius: s * 0.21, yRadius: s * 0.21)
    NSColor(calibratedRed: 0.957, green: 0.949, blue: 0.925, alpha: 1.0).setFill()
    bgPath.fill()

    NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.16, alpha: 1.0).setStroke()
    bgPath.lineWidth = max(2.0, s * 0.018)
    bgPath.stroke()

    // 2x2 Recessed Terminal Wells + Bauhaus Signal Badges
    let inner = card.insetBy(dx: s * 0.11, dy: s * 0.11)
    let gap = s * 0.04
    let cellW = (inner.width - gap) * 0.5
    let cellH = (inner.height - gap) * 0.5
    let colors: [NSColor] = [
        NSColor(calibratedRed: 0.855, green: 0.235, blue: 0.165, alpha: 1.0), // Vermilion
        NSColor(calibratedRed: 0.125, green: 0.365, blue: 0.820, alpha: 1.0), // Cobalt
        NSColor(calibratedRed: 0.095, green: 0.545, blue: 0.365, alpha: 1.0), // Emerald
        NSColor(calibratedRed: 0.865, green: 0.560, blue: 0.080, alpha: 1.0)  // Ochre
    ]

    for row in 0..<2 {
        for col in 0..<2 {
            let idx = row * 2 + col
            let cellRect = NSRect(
                x: inner.minX + CGFloat(col) * (cellW + gap),
                y: inner.minY + CGFloat(1 - row) * (cellH + gap),
                width: cellW,
                height: cellH
            )
            let well = NSBezierPath(roundedRect: cellRect, xRadius: s * 0.045, yRadius: s * 0.045)
            NSColor(calibratedRed: 0.094, green: 0.094, blue: 0.106, alpha: 1.0).setFill()
            well.fill()

            let barRect = NSRect(x: cellRect.minX + s * 0.025, y: cellRect.maxY - s * 0.055, width: cellRect.width * 0.55, height: s * 0.024)
            colors[idx].setFill()
            NSBezierPath(roundedRect: barRect, xRadius: s * 0.012, yRadius: s * 0.012).fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    try renderIcon(pixelSize: px).write(to: tempIconset.appendingPathComponent(name))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tempIconset.path, "-o", outputICNS.path]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: tempIconset)
exit(proc.terminationStatus)
