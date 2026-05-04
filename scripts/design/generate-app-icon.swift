import AppKit
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = "sonar/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.18, alpha: 1).setFill()
rect.fill()

if let bg = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.03, green: 0.08, blue: 0.23, alpha: 1), 0.0),
    (NSColor(calibratedRed: 0.04, green: 0.18, blue: 0.39, alpha: 1), 0.48),
    (NSColor(calibratedRed: 0.02, green: 0.42, blue: 0.54, alpha: 1), 1.0)
) {
    bg.draw(in: rect, angle: -90)
}

if let spotlight = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.14, green: 0.56, blue: 0.78, alpha: 1), 0.0),
    (NSColor(calibratedRed: 0.04, green: 0.25, blue: 0.55, alpha: 1), 0.45),
    (NSColor(calibratedRed: 0.03, green: 0.09, blue: 0.25, alpha: 1), 1.0)
) {
    spotlight.draw(in: NSRect(x: 0, y: 0, width: size, height: size), relativeCenterPosition: NSPoint(x: 0, y: -0.35))
}

func strokeArc(center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat, width: CGFloat, alpha: CGFloat) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    path.lineCapStyle = .round
    path.lineWidth = width

    NSColor(calibratedRed: 0.16, green: 0.96, blue: 1.0, alpha: 0.22 * alpha).setStroke()
    path.stroke()

    let glow = NSBezierPath()
    glow.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    glow.lineCapStyle = .round
    glow.lineWidth = width * 0.52
    NSColor(calibratedRed: 0.67, green: 1.0, blue: 1.0, alpha: 0.86 * alpha).setStroke()
    glow.stroke()
}

let center = NSPoint(x: 512, y: 365)
strokeArc(center: center, radius: 195, start: 20, end: 160, width: 44, alpha: 1.0)
strokeArc(center: center, radius: 320, start: 18, end: 162, width: 34, alpha: 0.88)
strokeArc(center: center, radius: 455, start: 18, end: 162, width: 26, alpha: 0.68)

func fillCircle(center: NSPoint, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
}

if let pulse = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.70, green: 1.0, blue: 1.0, alpha: 1), 0.0),
    (NSColor(calibratedRed: 0.13, green: 0.78, blue: 0.92, alpha: 1), 0.36),
    (NSColor(calibratedRed: 0.05, green: 0.38, blue: 0.64, alpha: 1), 1.0)
) {
    let pulseRect = NSRect(x: 300, y: 150, width: 424, height: 424)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: pulseRect).addClip()
    pulse.draw(in: pulseRect, relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()
}

fillCircle(center: center, radius: 44, color: NSColor(calibratedRed: 0.82, green: 1.0, blue: 1.0, alpha: 1))
fillCircle(center: NSPoint(x: 282, y: 705), radius: 15, color: NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.80, alpha: 1))
fillCircle(center: NSPoint(x: 540, y: 850), radius: 14, color: NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.80, alpha: 1))
fillCircle(center: NSPoint(x: 828, y: 760), radius: 14, color: NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.80, alpha: 1))

image.unlockFocus()

var proposedRect = rect
guard
    let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
else {
    fatalError("Could not create flattened image context")
}

context.setFillColor(CGColor(red: 0.03, green: 0.07, blue: 0.18, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))

guard
    let flattened = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: output) as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )
else {
    fatalError("Could not render icon PNG")
}

CGImageDestinationAddImage(destination, flattened, nil)
if !CGImageDestinationFinalize(destination) {
    fatalError("Could not write icon PNG")
}
print("Wrote \(output)")
