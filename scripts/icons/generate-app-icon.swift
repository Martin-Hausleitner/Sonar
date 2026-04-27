#!/usr/bin/env swift
// Generates the Sonar app icon (1024×1024 PNG).
//
// Run:
//   swift scripts/icons/generate-app-icon.swift
// Writes:
//   sonar/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png
//
// Design: dark blue-violet gradient background with a centered glowing
// sonar pulse — three concentric arcs radiating from a bright dot in the
// lower-third "horizon", echoing AirPods + radar without copying either.

import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let scale: CGFloat = 1
let pixelSize = size * scale

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(pixelSize),
    height: Int(pixelSize),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext creation failed") }

ctx.translateBy(x: 0, y: pixelSize)
ctx.scaleBy(x: scale, y: -scale)

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// MARK: - Background gradient (deep navy → violet)
let bgColors = [
    CGColor(red: 0.04, green: 0.06, blue: 0.16, alpha: 1.0),
    CGColor(red: 0.10, green: 0.08, blue: 0.28, alpha: 1.0),
    CGColor(red: 0.04, green: 0.20, blue: 0.34, alpha: 1.0)
] as CFArray
let bgGradient = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 0.55, 1.0])!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: 0),
    end:   CGPoint(x: 0, y: size),
    options: []
)

// MARK: - Subtle radial vignette (bright in lower-center)
let centerX = size / 2
let centerY = size * 0.62
let radial = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 0.55),
        CGColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawRadialGradient(
    radial,
    startCenter: CGPoint(x: centerX, y: centerY),
    startRadius: 0,
    endCenter:   CGPoint(x: centerX, y: centerY),
    endRadius:   size * 0.55,
    options: []
)

// MARK: - Sonar arcs (three concentric, radiating upward)
//
// Each arc is a partial circle drawn with a bright cyan stroke and an outer
// glow. Stroke widths and opacities decrease with radius to suggest fading
// into the distance.
struct Arc { let radius: CGFloat; let width: CGFloat; let alpha: CGFloat }
let arcs: [Arc] = [
    .init(radius: size * 0.18, width: 22, alpha: 1.0),
    .init(radius: size * 0.30, width: 18, alpha: 0.78),
    .init(radius: size * 0.43, width: 14, alpha: 0.55)
]

let arcCenter = CGPoint(x: centerX, y: centerY)
// Sweep from 200° to 340° (upper half, slightly past horizontal — looks like radar pulse).
let startAngle: CGFloat = .pi * 1.10
let endAngle:   CGFloat = .pi * 1.90

for arc in arcs {
    // Outer glow
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: 22,
        color: CGColor(red: 0.40, green: 0.95, blue: 1.0, alpha: 0.75 * arc.alpha)
    )
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.97, blue: 1.0, alpha: arc.alpha))
    ctx.setLineWidth(arc.width)
    ctx.setLineCap(.round)
    let path = CGMutablePath()
    path.addArc(
        center: arcCenter,
        radius: arc.radius,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: false
    )
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Bright nucleus
let coreRadius: CGFloat = size * 0.055
let coreGradient = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 1.0,  green: 1.0,  blue: 1.0,  alpha: 1.0),
        CGColor(red: 0.55, green: 0.97, blue: 1.0,  alpha: 1.0),
        CGColor(red: 0.10, green: 0.65, blue: 0.95, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 0.5, 1.0]
)!

ctx.saveGState()
ctx.setShadow(
    offset: .zero,
    blur: 60,
    color: CGColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 0.95)
)
ctx.drawRadialGradient(
    coreGradient,
    startCenter: arcCenter,
    startRadius: 0,
    endCenter:   arcCenter,
    endRadius:   coreRadius,
    options: []
)
ctx.restoreGState()

// MARK: - Tiny accent dots tracing the outer arc — suggesting peers detected
let dots: [(angle: CGFloat, distance: CGFloat)] = [
    (1.30, 0.38),
    (1.52, 0.45),
    (1.78, 0.40)
]
for d in dots {
    let r = size * d.distance
    let p = CGPoint(
        x: arcCenter.x + r * cos(.pi * d.angle),
        y: arcCenter.y + r * sin(.pi * d.angle)
    )
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: 14,
        color: CGColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 1.0)
    )
    ctx.setFillColor(CGColor(red: 1.0, green: 0.97, blue: 0.85, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
    ctx.restoreGState()
}

// MARK: - Encode and write
guard let cgImage = ctx.makeImage() else { fatalError("makeImage failed") }
let rep = NSBitmapImageRep(cgImage: cgImage)
rep.size = NSSize(width: size, height: size)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG encoding failed")
}

let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("sonar/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png")
try pngData.write(to: outURL)
print("Wrote \(outURL.path) — \(pngData.count) bytes")
