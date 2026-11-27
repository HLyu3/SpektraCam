//  AutoUpright.swift — the crop page's 自动: straighten and perspective found from the picture's own straight lines,
//  as Lightroom's Upright does it. Vision finds the edges' contours, simplified to straight segments; the long ones
//  that run near the picture's vertical or horizontal are the guides. A small search then finds the straighten angle
//  and the two keystones (`FrameCrop`'s own model) that make the guides upright and level — the verticals weigh most
//  (a building's converging sides), the horizontals less (a wall seen from the side legitimately recedes).

import CoreGraphics
import Foundation
import Vision

enum AutoUpright {
    /// A straight piece of an edge, in source pixels (y down).
    struct Segment: Equatable, Sendable {
        var a: CGPoint, b: CGPoint
        var length: Double { hypot(Double(b.x - a.x), Double(b.y - a.y)) }
    }

    struct Fit: Equatable, Sendable {
        var angle: Double          // degrees, as `FrameCrop.angle`
        var keystoneV: Double      // −1…1
        var keystoneH: Double
        var guides: Int            // segments it was fitted to
    }

    /// The fit for `image` (any size; ~1000 px is plenty), or nil when it has too few straight lines to trust.
    /// `turns`: the crop's quarter turns — with an odd number the photograph's upright vertical is its source's x.
    static func fit(_ image: CGImage, turns: Int) -> Fit? {
        let segments = self.segments(in: image)
        return fit(segments, size: CGSize(width: image.width, height: image.height), turns: turns)
    }

    // MARK: lines

    /// Long straight segments of the picture's edges.
    static func segments(in image: CGImage) -> [Segment] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2
        request.maximumImageDimension = 1024
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let result = request.results?.first else { return [] }
        let w = Double(image.width), h = Double(image.height)
        let minLength = 0.06 * min(w, h)
        var out: [Segment] = []
        for i in 0..<result.contourCount {
            guard let contour = try? result.contour(at: i),
                  let simple = try? contour.polygonApproximation(epsilon: 0.003) else { continue }
            let points = simple.normalizedPoints.map { CGPoint(x: Double($0.x) * w, y: (1 - Double($0.y)) * h) }
            guard points.count > 1 else { continue }
            for j in 0..<(points.count - 1) {
                let s = Segment(a: points[j], b: points[j + 1])
                if s.length >= minLength { out.append(s) }
            }
            if out.count > 600 { break }
        }
        return out
    }

    // MARK: the fit

    /// The search, on segments alone (so it can be checked without a picture).
    static func fit(_ segments: [Segment], size: CGSize, turns: Int) -> Fit? {
        let sideways = ((turns % 2) + 2) % 2 == 1
        // Guides: within 20° of the photograph's upright vertical or horizontal (in source axes).
        var verticals: [Segment] = [], horizontals: [Segment] = []
        for s in segments {
            let dx = abs(Double(s.b.x - s.a.x)), dy = abs(Double(s.b.y - s.a.y))
            let steep = atan2(dx, dy) < 20 * .pi / 180      // near the source's y axis
            let flat = atan2(dy, dx) < 20 * .pi / 180       // near its x axis
            if steep { if sideways { horizontals.append(s) } else { verticals.append(s) } }
            if flat { if sideways { verticals.append(s) } else { horizontals.append(s) } }
        }
        guard verticals.count >= 3 || horizontals.count >= 6 else { return nil }

        func cost(_ p: (a: Double, kv: Double, kh: Double)) -> Double {
            var c = 0.0
            func add(_ s: Segment, uprightIsSourceY: Bool, weight: Double) {
                let a = forward(s.a, p, size), b = forward(s.b, p, size)
                let dx = Double(b.x - a.x), dy = Double(b.y - a.y), len = max(hypot(dx, dy), 1e-6)
                let e = (uprightIsSourceY ? dx : dy) / len          // sine of the miss
                c += weight * s.length * min(e * e, 0.03)           // a guide far off is not a guide: capped
            }
            // The photograph's verticals run along source y unless it is turned sideways.
            for s in verticals { add(s, uprightIsSourceY: !sideways, weight: 1) }
            for s in horizontals { add(s, uprightIsSourceY: sideways, weight: 0.3) }
            // A little pull to no correction, so a scene that barely asks for one gets none.
            return c + size.width * (p.kv * p.kv + p.kh * p.kh) * 0.001
        }

        var p = (a: 0.0, kv: 0.0, kh: 0.0)
        var best = cost(p)
        var steps = (a: 4.0, kv: 0.4, kh: 0.4)
        for _ in 0..<60 {
            var moved = false
            for axis in 0..<3 {
                for sign in [-1.0, 1.0] {
                    var q = p
                    switch axis {
                    case 0: q.a = min(max(p.a + sign * steps.a, -15), 15)
                    case 1: q.kv = min(max(p.kv + sign * steps.kv, -1), 1)
                    default: q.kh = min(max(p.kh + sign * steps.kh, -1), 1)
                    }
                    let c = cost(q)
                    if c < best { best = c; p = q; moved = true }
                }
            }
            if !moved {
                steps = (steps.a / 2, steps.kv / 2, steps.kh / 2)
                if steps.a < 0.02 && steps.kv < 0.002 { break }
            }
        }
        // Rounded as the sliders show them; tiny corrections are none.
        let a = (p.a * 10).rounded() / 10, kv = (p.kv * 100).rounded() / 100, kh = (p.kh * 100).rounded() / 100
        return Fit(angle: abs(a) < 0.15 ? 0 : a, keystoneV: abs(kv) < 0.02 ? 0 : kv, keystoneH: abs(kh) < 0.02 ? 0 : kh,
                   guides: verticals.count + horizontals.count)
    }

    /// A source point where the corrected picture shows it: `FrameCrop.sourcePoint` the other way round (the keystone
    /// forward, then the straighten undone).
    static func forward(_ q: CGPoint, _ p: (a: Double, kv: Double, kh: Double), _ size: CGSize) -> CGPoint {
        let hw = Double(size.width) / 2, hh = Double(size.height) / 2
        let u = (Double(q.x) - hw) / hw, v = (Double(q.y) - hh) / hh
        let k = FrameCrop.keystoneStrength
        let d = max(1 + p.kh * k * u + p.kv * k * v, 0.05)
        let wx = u / d * hw, wy = v / d * hh                      // from the centre
        let r = p.a * .pi / 180, c = cos(r), s = sin(r)
        return CGPoint(x: hw + c * wx - s * wy, y: hh + s * wx + c * wy)
    }
}
