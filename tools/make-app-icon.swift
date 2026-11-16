// Draws the app icon (2026-11-16, the darkroom look): swift tools/make-app-icon.swift out.png, then sips to each size
// in ios/SpektraLab/Assets.xcassets/AppIcon.appiconset. Replaces make-app-icon.py (Pillow, the old red aperture).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 1024 px: warm graphite, a 35 mm frame of film with its sprocket holes, lit from behind by an amber safelight,
// and a six-bladed aperture in the frame.
let S = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
// background: graphite, a little lighter at the top
let bg = CGGradient(colorsSpace: cs, colors: [c(0.10, 0.095, 0.088), c(0.045, 0.043, 0.04)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
// grain
srand48(7)
for _ in 0..<60000 {
    let v = 0.3 + drand48() * 0.7
    ctx.setFillColor(c(v, v, v, 0.05))
    let d = 1 + drand48() * 1.6
    ctx.fill(CGRect(x: drand48() * Double(S), y: drand48() * Double(S), width: d, height: d))
}
// the film strip: a band across, cream-dark base
let strip = CGRect(x: -20, y: 262, width: 1064, height: 500)
ctx.setFillColor(c(0.16, 0.135, 0.11))
ctx.fill(strip)
// sprocket holes
ctx.setFillColor(c(0.045, 0.043, 0.04))
let holeW = 46.0, holeH = 62.0, pitch = 96.0
var x = -10.0
while x < 1040 {
    for y in [292.0, 670.0] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: holeW, height: holeH), cornerWidth: 9, cornerHeight: 9, transform: nil))
    }
    x += pitch
}
ctx.fillPath()
// the frame window, lit amber from behind
let frame = CGRect(x: 192, y: 382, width: 640, height: 260)
let win = CGPath(roundedRect: frame, cornerWidth: 18, cornerHeight: 18, transform: nil)
ctx.saveGState()
ctx.addPath(win); ctx.clip()
let glow = CGGradient(colorsSpace: cs, colors: [c(1.0, 0.86, 0.55), c(0.95, 0.62, 0.20), c(0.62, 0.30, 0.06)] as CFArray,
                      locations: [0, 0.45, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 360, options: [.drawsAfterEndLocation])
// the aperture: six blades as a hexagon opening, the blades a darker amber
let ap = CGPoint(x: 512, y: 512), R = 116.0, r = 52.0
ctx.setFillColor(c(0.40, 0.19, 0.04, 0.88))
ctx.addEllipse(in: CGRect(x: ap.x - R, y: ap.y - R, width: 2 * R, height: 2 * R))
ctx.fillPath()
for i in 0..<6 {
    let a0 = Double(i) * .pi / 3 + 0.18, a1 = a0 + .pi / 3
    ctx.move(to: CGPoint(x: ap.x + r * cos(a0), y: ap.y + r * sin(a0)))
    ctx.addLine(to: CGPoint(x: ap.x + R * cos(a0 - 0.55), y: ap.y + R * sin(a0 - 0.55)))
    ctx.setStrokeColor(c(0.98, 0.72, 0.30, 0.55)); ctx.setLineWidth(5); ctx.strokePath()
    _ = a1
}
var hex = [CGPoint]()
for i in 0..<6 { let a = Double(i) * .pi / 3 + 0.18; hex.append(CGPoint(x: ap.x + r * cos(a), y: ap.y + r * sin(a))) }
ctx.addLines(between: hex); ctx.closePath()
ctx.setFillColor(c(1.0, 0.95, 0.82)); ctx.fillPath()
ctx.restoreGState()
// edge text dots: a few frame-number ticks on the strip
ctx.setFillColor(c(0.94, 0.60, 0.19, 0.75))
for i in 0..<4 { ctx.fill(CGRect(x: 214 + Double(i) * 22, y: 360, width: 12, height: 6)) }
let img = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
