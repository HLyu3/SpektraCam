//  HDRExport.swift — the gain map an Enable HDR export carries (this app's; upstream makes it on the GPU at
//  full size, `HDRRendition.codes`). Here: the exported SDR picture drawn at most `maxEdge` px long in linear
//  Display P3, its log2 Y, the grain-aware gain of upstream's kernels (`HDRGrainGain.log2Gains`) with the
//  session's tables, coded against H (`HDRGainMap.code`). The file's SDR pixels are untouched.
//  shortcut: the map is ≤ 2048 px, so each map pixel spans several print pixels and the grain's own gain
//  (the κ term) is averaged away; port upstream's full-size GPU kernels if highlights look smooth-edged.

import CoreGraphics
import Foundation

enum HDRExport {
    static let maxEdge = 2048

    nonisolated static func attachment(for image: CGImage, curve: HDRSessionCurve) -> HDRGainMap.Attachment? {
        let long = max(image.width, image.height)
        let s = max(1, Int((Double(long) / Double(maxEdge)).rounded(.up)))
        let w = max(1, image.width / s), h = max(1, image.height / s)
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var l2y = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let y = HDRMath.luminance(Double(px[4 * i]), Double(px[4 * i + 1]), Double(px[4 * i + 2]))
            l2y[i] = Float(HDRGrainGain.l2y(y))
        }
        px = []
        // The local tone's width in the map's pixels: the print's grain-sized σ, shrunk with the map, 1 px at least.
        let sigma = max(1, HDRGrainGain.sigma(for: image) / Double(s))
        let gains = HDRGrainGain.log2Gains(l2y: l2y, width: w, height: h, tables: curve.tables, sigma: sigma)
        let headroom = curve.curve.headroom
        let codes = Data(gains.map { HDRGainMap.code(Double($0), headroom: headroom) })
        return HDRGainMap.Attachment(map: HDRGainMap.Map(width: w, height: h, subsample: s, codes: codes), headroom: headroom)
    }
}
