//  HDRSlide.swift — a slide's HDR (upstream `HDRGain`'s slide half, for this app's sessions): the engine renders
//  the slide twice — its SDR develop with the stretch (`scan_hdr_stretch`: the clear base at the page's white) and
//  one grain seed, then a rendition with each dye layer's shoulder moved up to H × the base (`scan_hdr_headroom`),
//  scaled by 1/H to fit — and the gain is the ratio of their luminance, per pixel. A print's HDR is the session's
//  curve instead (`HDRSessionCurve`). Here the two renditions are read back as bitmaps in the session's output
//  space (sRGB on the preview, the export's own later) at the preview's size.

import CoreGraphics
import Foundation

enum HDRSlide {
    /// H_content: two stops over the clear base (upstream's export headroom).
    static let headroom = 4.0

    /// The fields the SDR develop carries while a slide's HDR is on (and their "off", sent otherwise so a
    /// session that had them goes back).
    static func sdrWire(on: Bool, seed: Int) -> [String: ParamValue] {
        var wire: [String: ParamValue] = ["scan_hdr_stretch": .bool(on), "scan_hdr_headroom": .number(0),
                                          "scan_hdr_output_scale": .number(1)]
        if on { wire["grain_seed"] = .number(Double(max(1, abs(seed) % 2_147_483_647))) }
        return wire
    }

    /// The rendition's fields over the SDR develop's, and what puts the session back.
    static let renditionDelta: [String: ParamValue] = ["scan_hdr_stretch": .bool(false), "scan_hdr_headroom": .number(headroom),
                                                        "scan_hdr_output_scale": .number(1 / headroom)]
    static let restoreDelta: [String: ParamValue] = ["scan_hdr_stretch": .bool(true), "scan_hdr_headroom": .number(0),
                                                      "scan_hdr_output_scale": .number(1)]

    /// log2(HDR / SDR) of their luminance, per pixel (0 below a floor of SDR luminance, where the ratio is noise),
    /// capped at the rendition's headroom; with the picture's largest gain.
    nonisolated static func gainPlane(sdr: CGImage, hdr: CGImage) -> (log2Gain: [Float], width: Int, height: Int, top: Double)? {
        let w = sdr.width, h = sdr.height
        guard hdr.width == w, hdr.height == h,
              let s = linear(sdr), let r = linear(hdr) else { return nil }
        let cap = Float(log2(headroom * 1.05)), scale = Float(headroom)
        var out = [Float](repeating: 0, count: w * h)
        var top: Float = 0
        for i in 0..<(w * h) {
            let ys = 0.2126 * s[4 * i] + 0.7152 * s[4 * i + 1] + 0.0722 * s[4 * i + 2]
            guard ys > 1e-4 else { continue }
            let yh = (0.2126 * r[4 * i] + 0.7152 * r[4 * i + 1] + 0.0722 * r[4 * i + 2]) * scale
            let g = min(max(log2(max(yh / ys, 1)), 0), cap)
            out[i] = g
            top = max(top, g)
        }
        return (out, w, h, Double(exp2(top)))
    }

    /// The bitmap as linear extended sRGB floats, RGBA.
    nonisolated private static func linear(_ image: CGImage) -> [Float]? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    /// The plane as an ISO gain map's 8-bit codes against its own top.
    nonisolated static func attachment(_ p: (log2Gain: [Float], width: Int, height: Int, top: Double)) -> HDRGainMap.Attachment? {
        guard p.top > 1.01 else { return nil }
        let k = Float(255 / log2(p.top))
        let codes = Data(p.log2Gain.map { UInt8(min(255, max(0, ($0 * k).rounded()))) })
        return HDRGainMap.Attachment(map: HDRGainMap.Map(width: p.width, height: p.height, subsample: 1, codes: codes), headroom: p.top)
    }
}
