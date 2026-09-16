#!/usr/bin/env swift
import AppKit

let width = 660
let height = 420
let output = CommandLine.arguments.dropFirst().first ?? "dmg-background.png"
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("ERROR: could not create DMG artwork canvas\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// Dark graphite base with a slight vertical lift toward the top.
NSGradient(
    starting: NSColor(calibratedWhite: 0.070, alpha: 1),
    ending: NSColor(calibratedWhite: 0.105, alpha: 1)
)?.draw(in: canvas, angle: 90)

// A restrained orange glow behind Dimit and a neutral glow behind Applications.
let warmGlow = NSGradient(colors: [
    NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.06, alpha: 0.23),
    NSColor(calibratedRed: 0.55, green: 0.13, blue: 0.03, alpha: 0.08),
    NSColor.clear,
])
warmGlow?.draw(in: NSRect(x: 25, y: 70, width: 300, height: 300), relativeCenterPosition: .zero)

let neutralGlow = NSGradient(colors: [
    NSColor(calibratedWhite: 0.78, alpha: 0.07),
    NSColor.clear,
])
neutralGlow?.draw(in: NSRect(x: 360, y: 70, width: 260, height: 280), relativeCenterPosition: .zero)

func centeredText(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    NSAttributedString(string: text, attributes: attrs)
        .draw(in: NSRect(x: 0, y: y, width: CGFloat(width), height: 42))
}

centeredText(
    "Install Dimit",
    y: 328,
    font: .systemFont(ofSize: 29, weight: .semibold),
    color: NSColor(calibratedWhite: 0.965, alpha: 1)
)
centeredText(
    "Drag Dimit into Applications",
    y: 298,
    font: .systemFont(ofSize: 14, weight: .regular),
    color: NSColor(calibratedWhite: 0.73, alpha: 1)
)

// Fine guide rings around the two Finder icons.
for (cx, color) in [(175.0, NSColor(calibratedRed: 1, green: 0.38, blue: 0.08, alpha: 0.16)),
                    (485.0, NSColor(calibratedWhite: 0.72, alpha: 0.08))] {
    for radius in [82.0, 68.0, 55.0] {
        color.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(
            x: cx - radius,
            y: 195 - radius,
            width: radius * 2,
            height: radius * 2
        ))
        ring.lineWidth = 1
        ring.stroke()
    }
}

// Drag arrow between Dimit and Applications.
let arrowColor = NSColor(calibratedRed: 0.91, green: 0.40, blue: 0.17, alpha: 0.84)
arrowColor.setStroke()
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 285, y: 195))
shaft.line(to: NSPoint(x: 363, y: 195))
shaft.lineWidth = 3
shaft.stroke()

arrowColor.setFill()
let head = NSBezierPath()
head.move(to: NSPoint(x: 375, y: 195))
head.line(to: NSPoint(x: 360, y: 204))
head.line(to: NSPoint(x: 360, y: 186))
head.close()
head.fill()

// Small 800K→6500K warmth motif at the bottom.
let barRect = NSRect(x: 225, y: 50, width: 210, height: 3)
NSGradient(colors: [
    NSColor(calibratedRed: 1.00, green: 0.25, blue: 0.08, alpha: 0.82),
    NSColor(calibratedRed: 0.88, green: 0.86, blue: 0.79, alpha: 0.60),
])?.draw(in: barRect, angle: 0)

let smallAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11),
    .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 0.85),
]
NSAttributedString(string: "800K", attributes: smallAttrs)
    .draw(at: NSPoint(x: 232, y: 28))
NSAttributedString(string: "6500K", attributes: smallAttrs)
    .draw(at: NSPoint(x: 392, y: 28))

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("ERROR: could not encode DMG artwork as PNG\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: output), options: .atomic)
