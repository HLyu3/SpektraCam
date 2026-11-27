//  FrameCrop.swift — crop and straighten, applied to the photograph before it
//  is exposed (so the film edge frames the cropped picture).
//
//  The view the crop is drawn in is the source rotated clockwise by `angle`
//  about its centre; the crop is an upright rectangle in that view. Everything
//  is normalised to the source size, so one crop serves the preview, the
//  thumbnail and the full-size export.

import CoreGraphics
import Foundation

struct FrameCrop: Codable, Equatable, Sendable {
    /// Centre and size of the rectangle, as fractions of the source's width and height.
    var cx = 0.5, cy = 0.5, width = 1.0, height = 1.0
    /// Degrees clockwise, −45…45.
    var angle = 0.0
    var aspect: Aspect = .free
    /// The fixed ratio is turned on its side (3:2 → 2:3).
    var portrait = false
    /// Quarter turns clockwise, then — applied first — a left-right mirror; both after the crop. Optional so
    /// manifests written before them decode.
    var turns: Int? = nil
    var mirrored: Bool? = nil
    /// Perspective (keystone) correction, −1…1, applied FIRST, before the straighten: `keystoneV` widens the top
    /// (positive) or the bottom — converging verticals of a building made upright —, `keystoneH` the left or the right.
    /// Optional so older manifests decode; nil = none.
    var keystoneV: Double? = nil
    var keystoneH: Double? = nil

    static let maxAngle = 45.0
    /// The strongest keystone: at ±1 one edge is drawn 1/(1−0.4) ≈ 1.7× the other.
    static let keystoneStrength = 0.4
    var hasKeystone: Bool { (keystoneV ?? 0) != 0 || (keystoneH ?? 0) != 0 }
    static let minSide = 0.08

    enum Aspect: String, Codable, CaseIterable, Sendable, Identifiable {
        case free, original, square, r4x3, r3x2, r16x9
        var id: String { rawValue }
        var title: String {
            switch self {
            case .free: String(localized: "自由")
            case .original: String(localized: "原始")
            case .square: "1:1"
            case .r4x3: "4:3"
            case .r3x2: "3:2"
            case .r16x9: "16:9"
            }
        }
    }

    var isIdentity: Bool {
        cx == 0.5 && cy == 0.5 && width == 1 && height == 1 && angle == 0 && !isOriented && !hasKeystone
    }
    var quarterTurns: Int { ((turns ?? 0) % 4 + 4) % 4 }
    var isOriented: Bool { quarterTurns != 0 || mirrored == true }

    /// The picture as seen turned a quarter clockwise (`by` 1) or anticlockwise (−1).
    func turned(_ by: Int) -> FrameCrop { var c = self; c.turns = ((quarterTurns + by) % 4 + 4) % 4; return c.tidied }
    /// The picture as seen mirrored left-right, or top-bottom. Mirroring after a turn reverses the turn
    /// (H·R = R⁻¹·H), so the stored turn changes too.
    func flipped(vertically: Bool) -> FrameCrop {
        var c = self
        c.turns = ((vertically ? 2 : 0) - quarterTurns + 4) % 4
        c.mirrored = mirrored == true ? nil : true
        return c.tidied
    }
    private var tidied: FrameCrop { var c = self; if c.turns == 0 { c.turns = nil }; return c }

    /// Moves `channels`-wide pixels of a w×h picture through the mirror and turns.
    static func orient<T>(_ src: UnsafePointer<T>, width w: Int, height h: Int, channels n: Int,
                          turns: Int, mirrored: Bool, into dst: UnsafeMutablePointer<T>) {
        let ow = turns % 2 == 0 ? w : h
        nonisolated(unsafe) let (input, output) = (src, dst)
        DispatchQueue.concurrentPerform(iterations: turns % 2 == 0 ? h : w) { oy in
            for ox in 0..<ow {
                var (x, y): (Int, Int)
                switch turns {
                case 1: (x, y) = (oy, h - 1 - ox)
                case 2: (x, y) = (w - 1 - ox, h - 1 - oy)
                case 3: (x, y) = (w - 1 - oy, ox)
                default: (x, y) = (ox, oy)
                }
                if mirrored { x = w - 1 - x }
                let s = input + (y * w + x) * n, d = output + (oy * ow + ox) * n
                for k in 0..<n { d[k] = s[k] }
            }
        }
    }

    /// Width over height the rectangle is held to, in pixels; nil when free.
    func ratio(source: CGSize) -> CGFloat? {
        let r: CGFloat
        switch aspect {
        case .free: return nil
        case .original: r = max(source.width, source.height) / max(min(source.width, source.height), 1)
        case .square: return 1
        case .r4x3: r = 4.0 / 3
        case .r3x2: r = 3.0 / 2
        case .r16x9: r = 16.0 / 9
        }
        return portrait ? 1 / r : r
    }

    /// The rectangle in the view, in source pixels.
    func rect(in source: CGSize) -> CGRect {
        let w = width * source.width, h = height * source.height
        return CGRect(x: cx * source.width - w / 2, y: cy * source.height - h / 2, width: w, height: h)
    }

    mutating func setRect(_ r: CGRect, in source: CGSize) {
        cx = r.midX / source.width; cy = r.midY / source.height
        width = r.width / source.width; height = r.height / source.height
    }

    func outputSize(source: CGSize) -> (width: Int, height: Int) {
        (max(1, Int((width * source.width).rounded())), max(1, Int((height * source.height).rounded())))
    }

    /// The source point under a view point (both in source pixels, y down).
    func sourcePoint(_ v: CGPoint, in source: CGSize) -> CGPoint {
        let a = angle * .pi / 180, c = cos(a), s = sin(a)
        let dx = v.x - source.width / 2, dy = v.y - source.height / 2
        return unwarp(CGPoint(x: source.width / 2 + c * dx + s * dy, y: source.height / 2 - s * dx + c * dy), in: source)
    }

    /// A point of the keystone-corrected picture back on the photograph (both in source pixels). The correction is a
    /// projective map about the centre, in coordinates −1…1 across each side: shown (u, v) comes from
    /// (u, v) / (1 − h·u − v·v'), h and v the two keystones × `keystoneStrength`. Far outside the picture: a point off it.
    func unwarp(_ q: CGPoint, in source: CGSize) -> CGPoint {
        guard hasKeystone else { return q }
        let hw = source.width / 2, hh = source.height / 2
        let u = (q.x - hw) / hw, v = (q.y - hh) / hh
        let d = 1 - (keystoneH ?? 0) * Self.keystoneStrength * u - (keystoneV ?? 0) * Self.keystoneStrength * v
        guard d > 0.05 else { return CGPoint(x: -1e9, y: -1e9) }
        return CGPoint(x: hw + u / d * hw, y: hh + v / d * hh)
    }

    /// `image` with only the keystone correction, at its own size (the crop page's picture).
    func keystoned(_ image: CGImage, space: CGColorSpace) -> CGImage? {
        let (w, h) = (image.width, image.height)
        guard let inCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let outCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let inData = inCtx.data, let outData = outCtx.data else { return nil }
        inCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The crop page redraws this while a slider moves: plain Float arithmetic, nearest pixel, no per-pixel calls
        // (sampling through `sourcePoint` took long enough that a drag queued redraws and none landed).
        nonisolated(unsafe) let src = inData.assumingMemoryBound(to: UInt32.self)
        nonisolated(unsafe) let dst = outData.assumingMemoryBound(to: UInt32.self)
        let kh = Float((keystoneH ?? 0) * Self.keystoneStrength), kv = Float((keystoneV ?? 0) * Self.keystoneStrength)
        let hw = Float(w) / 2, hh = Float(h) / 2
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let v = (Float(y) + 0.5 - hh) / hh
            for x in 0..<w {
                let u = (Float(x) + 0.5 - hw) / hw
                let d = 1 - kh * u - kv * v
                var px: UInt32 = 0xFF00_0000                       // off the photograph: black
                if d > 0.05 {
                    let sx = Int(hw + u / d * hw), sy = Int(hh + v / d * hh)
                    if sx >= 0, sy >= 0, sx < w, sy < h { px = src[sy * w + sx] }
                }
                dst[y * w + x] = px
            }
        }
        return outCtx.makeImage()
    }

    /// Draws `image` through this crop by resampling each output pixel (bilinear, RGBA8): the way a keystone, which
    /// no affine context transform can draw, is rendered.
    private func sampled(_ image: CGImage, space: CGColorSpace) -> CGImage? {
        let (w, h) = (image.width, image.height)
        let source = CGSize(width: w, height: h)
        let out = outputSize(source: source), r = rect(in: source)
        guard let inCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let outCtx = CGContext(data: nil, width: out.width, height: out.height, bitsPerComponent: 8,
                                     bytesPerRow: out.width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let inData = inCtx.data, let outData = outCtx.data else { return nil }
        inCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // memory's first row is the top
        nonisolated(unsafe) let src = inData.assumingMemoryBound(to: UInt8.self)
        nonisolated(unsafe) let dst = outData.assumingMemoryBound(to: UInt8.self)
        let ow = out.width, crop = self
        DispatchQueue.concurrentPerform(iterations: out.height) { oy in
            for ox in 0..<ow {
                let p = crop.sourcePoint(CGPoint(x: r.minX + CGFloat(ox) + 0.5, y: r.minY + CGFloat(oy) + 0.5), in: source)
                let fx = min(max(Float(p.x) - 0.5, 0), Float(w - 1)), fy = min(max(Float(p.y) - 0.5, 0), Float(h - 1))
                let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                let tx = fx - Float(x0), ty = fy - Float(y0)
                let o = (oy * ow + ox) * 4
                for k in 0..<3 {
                    let a = Float(src[(y0 * w + x0) * 4 + k]), b = Float(src[(y0 * w + x1) * 4 + k])
                    let c = Float(src[(y1 * w + x0) * 4 + k]), d = Float(src[(y1 * w + x1) * 4 + k])
                    let top = a + (b - a) * tx, bottom = c + (d - c) * tx
                    dst[o + k] = UInt8(min(max((top + (bottom - top) * ty).rounded(), 0), 255))
                }
                dst[o + 3] = 255
            }
        }
        return outCtx.makeImage()
    }

    /// Every corner of the rectangle is on the photograph.
    func fits(in source: CGSize) -> Bool {
        guard width >= Self.minSide / 2, height >= Self.minSide / 2 else { return false }
        let r = rect(in: source), e = 0.5
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].allSatisfy {
            let p = sourcePoint($0, in: source)
            return p.x >= -e && p.y >= -e && p.x <= source.width + e && p.y <= source.height + e
        }
    }

    /// This crop pulled towards the centre and shrunk by the least that makes it fit.
    func fitted(in source: CGSize) -> FrameCrop {
        if fits(in: source) { return self }
        var lo = 0.0, hi = 1.0
        func at(_ t: Double) -> FrameCrop {
            var g = self
            g.cx = 0.5 + (cx - 0.5) * t; g.cy = 0.5 + (cy - 0.5) * t
            g.width = width * t; g.height = height * t
            return g
        }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if at(mid).fits(in: source) { lo = mid } else { hi = mid }
        }
        return at(lo)
    }

    /// Draws `image` (the uncropped photograph at any size) through this crop.
    func render(_ image: CGImage, space: CGColorSpace) -> CGImage? {
        if hasKeystone {
            var flat = self; flat.turns = nil; flat.mirrored = nil
            guard let cut = flat.sampled(image, space: space) else { return nil }
            guard isOriented, let ctx = CGContext(data: nil, width: cut.width, height: cut.height, bitsPerComponent: 8,
                                                  bytesPerRow: cut.width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let data = ctx.data?.assumingMemoryBound(to: UInt32.self) else { return cut }
            ctx.draw(cut, in: CGRect(x: 0, y: 0, width: cut.width, height: cut.height))
            let t = quarterTurns, (ow, oh) = t % 2 == 0 ? (cut.width, cut.height) : (cut.height, cut.width)
            guard let turned = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: ow * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let to = turned.data?.assumingMemoryBound(to: UInt32.self) else { return nil }
            Self.orient(data, width: cut.width, height: cut.height, channels: 1, turns: t, mirrored: mirrored == true, into: to)
            return turned.makeImage()
        }
        let source = CGSize(width: image.width, height: image.height)
        let out = outputSize(source: source), r = rect(in: source)
        guard let ctx = CGContext(data: nil, width: out.width, height: out.height, bitsPerComponent: 8,
                                  bytesPerRow: out.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Work with y down, as the model does; the image is flipped back last.
        ctx.translateBy(x: 0, y: CGFloat(out.height)); ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        ctx.translateBy(x: source.width / 2, y: source.height / 2)
        ctx.rotate(by: angle * .pi / 180)
        ctx.translateBy(x: -source.width / 2, y: -source.height / 2)
        ctx.translateBy(x: 0, y: source.height); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: source))
        guard isOriented, let data = ctx.data?.assumingMemoryBound(to: UInt32.self) else { return ctx.makeImage() }
        let t = quarterTurns, (ow, oh) = t % 2 == 0 ? (out.width, out.height) : (out.height, out.width)
        guard let turned = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: ow * 4,
                                     space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let to = turned.data?.assumingMemoryBound(to: UInt32.self) else { return nil }
        Self.orient(data, width: out.width, height: out.height, channels: 1, turns: t, mirrored: mirrored == true, into: to)
        return turned.makeImage()
    }
}

extension DecodedFrame {
    /// The frame through `crop`. A plain crop is a row copy; a straighten resamples (bilinear).
    func applying(_ crop: FrameCrop?) -> DecodedFrame {
        guard let crop, !crop.isIdentity else { return self }
        guard crop.isOriented else { return cut(crop) }
        var flat = crop; flat.turns = nil; flat.mirrored = nil
        let piece = cut(flat), t = crop.quarterTurns
        var output = [Float](repeating: 0, count: piece.width * piece.height * 3)
        piece.pixels.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                guard let from = src.baseAddress, let to = dst.baseAddress else { return }
                FrameCrop.orient(from, width: piece.width, height: piece.height, channels: 3, turns: t,
                                 mirrored: crop.mirrored == true, into: to)
            }
        }
        return t % 2 == 0 ? DecodedFrame(pixels: FloatRGBPixels(output), width: piece.width, height: piece.height)
            : DecodedFrame(pixels: FloatRGBPixels(output), width: piece.height, height: piece.width)
    }

    private func cut(_ crop: FrameCrop) -> DecodedFrame {
        guard !crop.isIdentity else { return self }
        let source = CGSize(width: width, height: height)
        let out = crop.outputSize(source: source), r = crop.rect(in: source)
        if crop.angle == 0 && !crop.hasKeystone {
            let x = min(max(Int(r.minX.rounded()), 0), width - 1), y = min(max(Int(r.minY.rounded()), 0), height - 1)
            return cropped(to: (x, y, min(out.width, width - x), min(out.height, height - y)))
        }
        let a = crop.angle * .pi / 180, c = Float(cos(a)), s = Float(sin(a))
        let (w, h, ow, oh) = (width, height, out.width, out.height)
        let halfW = Float(w) / 2, halfH = Float(h) / 2
        let kh = Float((crop.keystoneH ?? 0) * FrameCrop.keystoneStrength), kv = Float((crop.keystoneV ?? 0) * FrameCrop.keystoneStrength)
        let keystone = crop.hasKeystone
        let originX = Float(r.minX) + 0.5 - halfW, originY = Float(r.minY) + 0.5 - halfH
        var output = [Float](repeating: 0, count: ow * oh * 3)
        pixels.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                guard let from = src.baseAddress, let base = dst.baseAddress else { return }
                nonisolated(unsafe) let input = from
                nonisolated(unsafe) let to = base
                // shortcut: plain Swift bilinear on all cores; move to vImage/Metal if a 48 MP straighten is too slow.
                DispatchQueue.concurrentPerform(iterations: oh) { oy in
                    let dy = originY + Float(oy)
                    var o = to + oy * ow * 3
                    for ox in 0..<ow {
                        let dx = originX + Float(ox)
                        var qx = c * dx + s * dy, qy = -s * dx + c * dy       // from the centre
                        if keystone {                                         // `FrameCrop.unwarp`, inline
                            let u = qx / halfW, v = qy / halfH
                            let d = max(1 - kh * u - kv * v, 0.05)
                            qx = u / d * halfW; qy = v / d * halfH
                        }
                        let fx = min(max(halfW + qx - 0.5, 0), Float(w - 1))
                        let fy = min(max(halfH + qy - 0.5, 0), Float(h - 1))
                        let x0 = Int(fx), y0 = Int(fy)
                        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                        let tx = fx - Float(x0), ty = fy - Float(y0)
                        let p00 = input + (y0 * w + x0) * 3, p10 = input + (y0 * w + x1) * 3
                        let p01 = input + (y1 * w + x0) * 3, p11 = input + (y1 * w + x1) * 3
                        for k in 0..<3 {
                            let top = p00[k] + (p10[k] - p00[k]) * tx
                            let bottom = p01[k] + (p11[k] - p01[k]) * tx
                            o[k] = top + (bottom - top) * ty
                        }
                        o += 3
                    }
                }
            }
        }
        return DecodedFrame(pixels: FloatRGBPixels(output), width: ow, height: oh)
    }
}
