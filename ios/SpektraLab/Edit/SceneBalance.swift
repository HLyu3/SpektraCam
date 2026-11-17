//  SceneBalance.swift — 白平衡 at the decode: gains on the photograph's linear light before the film sees it, set by
//  an eyedropper (a tap on something that should be grey). Upstream's Decode › White Balance + its eyedropper
//  (`NeutralPick.decodeBalance`), simplified: upstream re-solves the RAW decode's temperature and tint; here the
//  decoded frame (scene-linear ProPhoto, any format) is scaled per channel, which is the same correction to first
//  order and needs no change to the decoders. Stored as `PhotoRecipe.sceneBalance` (r, g, b gains), nil = as shot.

import Foundation

enum SceneBalance {
    /// Gains that make a linear (r, g, b) grey, keeping its brightness; nil when it is too dark to have a colour.
    static func gains(neutralizing c: SIMD3<Double>) -> [Double]? {
        guard c.x > 1e-4, c.y > 1e-4, c.z > 1e-4, c.y > 0.002 else { return nil }
        let g = SIMD3(c.y / c.x, 1, c.y / c.z)
        // Hold the weighted level (ProPhoto's luminance weights) where it was.
        let w = SIMD3(0.288, 0.712, 0.0)
        let before = (c * w).sum(), after = (c * g * w).sum()
        let k = after > 0 ? before / after : 1
        return [g.x * k, g.y * k, g.z * k]
    }

    /// Two corrections in a row are one set of gains.
    static func combined(_ a: [Double]?, _ b: [Double]) -> [Double] {
        guard let a, a.count == 3 else { return b }
        return [a[0] * b[0], a[1] * b[1], a[2] * b[2]]
    }

    /// In words, what the gains do to the picture (the panel's line): warmer or cooler, greener or more magenta.
    static func describe(_ g: [Double]) -> String {
        let warm = log2(g[0] / g[2]), green = log2(g[1] / sqrt(g[0] * g[2]))
        func word(_ v: Double, _ plus: String, _ minus: String) -> String? {
            let m = abs(v)
            guard m >= 0.03 else { return nil }
            return (m < 0.15 ? "略" : m < 0.5 ? "" : "明显") + (v > 0 ? plus : minus)
        }
        let parts = [word(warm, "暖", "冷"), word(green, "偏绿", "偏品红")].compactMap { $0 }
        return parts.isEmpty ? "接近原样" : parts.joined(separator: " · ")
    }
}

extension DecodedFrame {
    /// The frame with `gains` on each channel. In place: every caller hands over a frame it has just decoded and
    /// owns alone (a full-size copy would double an export's memory).
    func balanced(_ gains: [Double]?) -> DecodedFrame {
        guard let gains, gains.count == 3, gains != [1, 1, 1] else { return self }
        let g = (Float(gains[0]), Float(gains[1]), Float(gains[2]))
        let (w, h) = (width, height)
        pixels.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            nonisolated(unsafe) let p = UnsafeMutablePointer(mutating: base)
            DispatchQueue.concurrentPerform(iterations: h) { y in
                var q = p + y * w * 3
                for _ in 0..<w { q[0] *= g.0; q[1] *= g.1; q[2] *= g.2; q += 3 }
            }
        }
        return self
    }

    /// A smaller copy (nearest pixel), its long edge at most `longEdge`.
    func downsampled(longEdge: Int) -> DecodedFrame {
        let long = max(width, height)
        guard long > longEdge else { return self }
        let k = Double(long) / Double(longEdge)
        let w = max(1, Int(Double(width) / k)), h = max(1, Int(Double(height) / k))
        var out = [Float](repeating: 0, count: w * h * 3)
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let sy = min(Int((Double(y) + 0.5) * k), height - 1)
                for x in 0..<w {
                    let sx = min(Int((Double(x) + 0.5) * k), width - 1)
                    let s = (sy * width + sx) * 3, d = (y * w + x) * 3
                    out[d] = p[s]; out[d + 1] = p[s + 1]; out[d + 2] = p[s + 2]
                }
            }
        }
        return DecodedFrame(pixels: FloatRGBPixels(out), width: w, height: h)
    }

    /// The mean linear colour of a 9 × 9 patch about the normalised point `n` (top-left).
    func sample(at n: CGPoint) -> SIMD3<Double>? {
        guard (0...1).contains(n.x), (0...1).contains(n.y), width > 0, height > 0 else { return nil }
        let cx = min(max(Int(n.x * CGFloat(width)), 0), width - 1), cy = min(max(Int(n.y * CGFloat(height)), 0), height - 1)
        var sum = SIMD3<Double>(0, 0, 0), count = 0.0
        pixels.withUnsafeBufferPointer { p in
            for y in max(cy - 4, 0)...min(cy + 4, height - 1) {
                for x in max(cx - 4, 0)...min(cx + 4, width - 1) {
                    let i = (y * width + x) * 3
                    sum += SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2])); count += 1
                }
            }
        }
        return count > 0 ? sum / count : nil
    }
}
