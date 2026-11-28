//  DoubleExposure.swift — two exposures on one frame of film (多重曝光), after upstream's model (RFC-047/048), as the
//  half-frame pair's sibling: the two pictures are composed into one LINEAR picture, saved as a new library photo
//  (10-bit ProPhoto HEIF, as a pair), and from then on it develops as one negative — the sum is the scene the film saw.
//
//  The bottom exposure sets the frame (its whole picture, its shape); the top is laid over it through a window of
//  the frame's shape (moved and zoomed). Light ADDS: each exposure is metered alone to mid grey, then given its share
//  of one normal exposure — Balance is the top's share (0.1…0.9), the bottom gets the rest (upstream: each half a
//  normal exposure, so the frame as a whole is one) — and its own stops on top.
//
//  Each exposure comes as its photograph shows it — its own crop, straighten, turns and white balance (`picture`) —
//  and the top can be turned and mirrored on top of that. The sheet's preview is the real composition (linear add,
//  the meters, the gains) at ~700 px on the GPU (`preview`), tone-mapped for the screen; the film's own look comes after, at develop.
//  shortcut: upstream's per-exposure "alone" preview is left out.

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

struct DoubleSpec: Codable, Equatable, Sendable, Identifiable {
    var id: String { "double" + bottom.uuidString + top.uuidString }
    var bottom: UUID
    var top: UUID
    /// The top's share of the frame's light.
    var balance = 0.5
    var bottomEV = 0.0
    var topEV = 0.0
    /// Which part of the top lies over the frame (the window has the frame's shape).
    var topPlace = PairPlacement()
    /// The top turned clockwise (quarter turns) and mirrored, after its own crop. Optional: older specs lack them.
    var topTurns: Int? = nil
    var topMirrored: Bool? = nil

    /// The top's extra orientation as a crop that only turns: applied after the photograph's own crop.
    var topOrientation: FrameCrop? {
        let t = (((topTurns ?? 0) % 4) + 4) % 4
        guard t != 0 || topMirrored == true else { return nil }
        var c = FrameCrop(); c.turns = t; c.mirrored = topMirrored == true ? true : nil
        return c
    }

    static let balanceRange = 0.1...0.9
    /// The longest side the piece is composed at: three float frames of it must fit in memory.
    static let longEdgeCap = 6000.0

    var swapped: DoubleSpec {
        DoubleSpec(bottom: top, top: bottom, balance: 1 - balance, bottomEV: topEV, topEV: bottomEV)
    }

    /// The composition: `bottom` whole, `top` (already oriented) through its window, metered, lit and added.
    static func compose(bottom: DecodedFrame, top: DecodedFrame, spec: DoubleSpec) -> DecodedFrame {
        let w = DoubleComposer.window(spec.topPlace, in: CGSize(width: top.width, height: top.height),
                                      aspect: CGFloat(bottom.width) / CGFloat(max(bottom.height, 1)))
        // Metered on the picture itself (black round a shrunk top would fool the meter), then laid.
        let topMeter = PairComposer.meter(top)
        let laid = DoubleComposer.laid(top, window: w, width: bottom.width, height: bottom.height)
        let gains = DoubleComposer.gains(spec, bottomMeter: PairComposer.meter(bottom), topMeter: topMeter)
        return DoubleComposer.add(bottom, laid, gains: gains)
    }
}

enum DoubleComposer {
    /// The top may be shrunk to this (zoom < 1: smaller than the frame, black round it — no light there).
    static let minZoom = 0.3

    /// The window `place` sees of a picture of `size`, with the frame's `aspect` (width / height), in fractions of
    /// the picture. Unlike a pair's hole it may run past the picture's edges: there the top adds no light. At zoom 1
    /// the picture just covers the frame; `cx`, `cy` (the picture point at the frame's centre) stay on the picture.
    static func window(_ place: PairPlacement, in size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let fitH = size.width / size.height > aspect ? size.height : size.width / aspect
        let z = min(max(place.zoom, minZoom), PairPlacement.maxZoom)
        let w = fitH * aspect / z / size.width, h = fitH / z / size.height
        return CGRect(x: place.cx - w / 2, y: place.cy - h / 2, width: w, height: h)
    }

    static func clamped(_ place: PairPlacement) -> PairPlacement {
        var p = place
        p.zoom = min(max(place.zoom, minZoom), PairPlacement.maxZoom)
        p.cx = min(max(place.cx, 0), 1); p.cy = min(max(place.cy, 0), 1)
        return p
    }

    /// The top as it lies on a frame `width` × `height`: window `r` of `picture` sampled bilinearly, black off it.
    static func laid(_ picture: DecodedFrame, window r: CGRect, width w: Int, height h: Int) -> DecodedFrame {
        let sw = picture.width, sh = picture.height
        var out = [Float](repeating: 0, count: w * h * 3)
        picture.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let fy = (Double(r.minY) + (Double(y) + 0.5) / Double(h) * Double(r.height)) * Double(sh) - 0.5
                    guard fy > -0.5, fy < Double(sh) - 0.5 else { continue }
                    let cy = min(max(fy, 0), Double(sh - 1)), y0 = Int(cy), y1 = min(y0 + 1, sh - 1), ty = Float(cy - Double(y0))
                    for x in 0..<w {
                        let fx = (Double(r.minX) + (Double(x) + 0.5) / Double(w) * Double(r.width)) * Double(sw) - 0.5
                        guard fx > -0.5, fx < Double(sw) - 0.5 else { continue }
                        let cx = min(max(fx, 0), Double(sw - 1)), x0 = Int(cx), x1 = min(x0 + 1, sw - 1), tx = Float(cx - Double(x0))
                        for c in 0..<3 {
                            let a = src[(y0 * sw + x0) * 3 + c], b = src[(y0 * sw + x1) * 3 + c]
                            let d = src[(y1 * sw + x0) * 3 + c], e = src[(y1 * sw + x1) * 3 + c]
                            let top = a + (b - a) * tx, bottom = d + (e - d) * tx
                            dst[(y * w + x) * 3 + c] = top + (bottom - top) * ty
                        }
                    }
                }
            }
        }
        return DecodedFrame(pixels: FloatRGBPixels(out), width: w, height: h)
    }

    /// The sheet's live preview on the GPU (a drag recomputed on the CPU stuttered): each picture as a linear
    /// CIImage made once, here only laid (affine), lit (colour matrix), added and tone-mapped for the screen. The same
    /// sum as `DoubleSpec.compose`, which still makes the photo itself.
    struct Layers: @unchecked Sendable {
        let bottom: CIImage, top: CIImage
        let width: CGFloat, height: CGFloat, topWidth: CGFloat, topHeight: CGFloat
        let bottomMeter: Double, topMeter: Double
    }

    static func layers(bottom: DecodedFrame, top: DecodedFrame) -> Layers? {
        guard let b = ciImage(bottom), let t = ciImage(top) else { return nil }
        return Layers(bottom: b, top: t, width: CGFloat(bottom.width), height: CGFloat(bottom.height),
                      topWidth: CGFloat(top.width), topHeight: CGFloat(top.height),
                      bottomMeter: PairComposer.meter(bottom), topMeter: PairComposer.meter(top))
    }

    private static func ciImage(_ frame: DecodedFrame) -> CIImage? {
        guard let linear = ImageDecoder.linearProPhoto else { return nil }
        let n = frame.width * frame.height
        var rgba = [Float16](repeating: 1, count: n * 4)
        frame.pixels.withUnsafeBufferPointer { p in
            for i in 0..<n { rgba[i * 4] = Float16(p[i * 3]); rgba[i * 4 + 1] = Float16(p[i * 3 + 1]); rgba[i * 4 + 2] = Float16(p[i * 3 + 2]) }
        }
        return CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: frame.width * 8,
                       size: CGSize(width: frame.width, height: frame.height), format: .RGBAh, colorSpace: linear)
    }

    private static let previewContext = CIContext(options: [.cacheIntermediates: false,
                                                            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any])

    static func preview(_ l: Layers, spec: DoubleSpec) -> CGImage? {
        let r = window(spec.topPlace, in: CGSize(width: l.topWidth, height: l.topHeight), aspect: l.width / max(l.height, 1))
        // The window onto the frame; Core Image is y up, the window y down.
        let sx = l.width / (r.width * l.topWidth), sy = l.height / (r.height * l.topHeight)
        let laid = l.top
            .transformed(by: CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                               tx: -sx * r.minX * l.topWidth,
                                               ty: l.height - l.topHeight * sy * (1 - r.minY)))
        let frame = CGRect(x: 0, y: 0, width: l.width, height: l.height)
        let g = gains(spec, bottomMeter: l.bottomMeter, topMeter: l.topMeter)
        func lit(_ image: CIImage, _ k: Float) -> CIImage {
            let f = CIFilter.colorMatrix()
            f.inputImage = image
            f.rVector = CIVector(x: CGFloat(k), y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: CGFloat(k), z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: CGFloat(k), w: 0)
            return f.outputImage ?? image
        }
        let sum = lit(laid, g.1).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: lit(l.bottom, g.0)])
            .cropped(to: frame)
        let tone = CIFilter.toneMapHeadroom()
        tone.inputImage = sum.composited(over: CIImage(color: .black).cropped(to: frame))
        tone.sourceHeadroom = 4
        tone.targetHeadroom = 1
        guard let out = tone.outputImage, let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        return previewContext.createCGImage(out, from: frame, format: .RGBA8, colorSpace: p3)
    }

    /// Each exposure's gain: its meter, its stops, its share of the light.
    static func gains(_ spec: DoubleSpec, bottomMeter: Double, topMeter: Double) -> (Float, Float) {
        let b = min(max(spec.balance, DoubleSpec.balanceRange.lowerBound), DoubleSpec.balanceRange.upperBound)
        return (Float(pow(2, bottomMeter + spec.bottomEV) * (1 - b)), Float(pow(2, topMeter + spec.topEV) * b))
    }

    /// `bottom` × its gain + `top` × its gain, pixel by pixel (`top` already laid at the bottom's size).
    static func add(_ bottom: DecodedFrame, _ top: DecodedFrame, gains: (Float, Float)) -> DecodedFrame {
        let w = bottom.width, h = bottom.height
        var out = [Float](repeating: 0, count: w * h * 3)
        bottom.pixels.withUnsafeBufferPointer { b in
            top.pixels.withUnsafeBufferPointer { t in
                out.withUnsafeMutableBufferPointer { o in
                    for y in 0..<h {
                        for x in 0..<w {
                            let i = (y * w + x) * 3
                            let j = (min(y, top.height - 1) * top.width + min(x, top.width - 1)) * 3
                            for c in 0..<3 { o[i + c] = b[i + c] * gains.0 + t[j + c] * gains.1 }
                        }
                    }
                }
            }
        }
        return DecodedFrame(pixels: FloatRGBPixels(out), width: w, height: h)
    }
}

/// Choose which is the bottom, the balance and each exposure's stops, and where the top lies; then compose.
struct DoubleSheet: View {
    @ObservedObject var model: ViewModel
    @State var spec: DoubleSpec
    /// The double exposure being made again (its file replaced, its look and crop kept); nil = a new photo.
    var replacing: UUID? = nil
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var start: PairPlacement?
    /// Each photograph as it shows itself (crop, turns, white balance), small, by id.
    @State private var frames: [UUID: DecodedFrame] = [:]
    /// The composition for the screen, and the top's size as it lies (oriented) — what the gesture maps through.
    @State private var picture: CGImage?
    @State private var topSize: CGSize = .zero
    /// The two pictures ready for the GPU preview; made again on a swap or a turn of the top.
    @State private var layers: DoubleComposer.Layers?

    static let previewEdge = 720

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                preview.padding(.top, 8)
                HStack(spacing: 18) {
                    Button { spec = spec.swapped } label: {
                        Label(String(localized: "上下互换"), systemImage: "arrow.up.arrow.down")
                    }
                    Button { spec.topTurns = ((spec.topTurns ?? 0) + 1) % 4 } label: {
                        Label(String(localized: "旋转上层"), systemImage: "rotate.right")
                    }
                    Button { spec.topMirrored = spec.topMirrored == true ? nil : true } label: {
                        Label(String(localized: "翻转上层"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                }
                .font(.footnote.weight(.semibold))
                VStack(spacing: 10) {
                    FinishSlider(title: String(localized: "比例"), value: $spec.balance, range: DoubleSpec.balanceRange, rest: 0.5,
                                 text: { String(format: String(localized: "上 %d%% · 下 %d%%"), Int(($0 * 100).rounded()), 100 - Int(($0 * 100).rounded())) })
                    FinishSlider(title: String(localized: "底片曝光"), value: $spec.bottomEV, range: -2...2, text: { String(format: "%+.1f EV", $0) })
                    FinishSlider(title: String(localized: "上层曝光"), value: $spec.topEV, range: -2...2, text: { String(format: "%+.1f EV", $0) })
                    Text(String(localized: "像胶片相机不过片再按一次快门：两张的光叠加在同一格上。每张先各自测光，「比例」决定上层占多少光，合起来是一次正常曝光。暗的地方会透出另一张，亮的地方盖住。预览是真实的叠加结果，胶片的颜色和颗粒在生成后冲洗时加上。"))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    working = true
                    Task {
                        let made = await model.makeDouble(spec, replacing: replacing)
                        working = false
                        if made != nil { done(); dismiss() }
                    }
                } label: {
                    HStack {
                        if working { ProgressView().tint(.white) }
                        Text(working ? String(localized: "正在合成…") : replacing == nil ? String(localized: "生成多重曝光") : String(localized: "更新多重曝光"))
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.labRed, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(working)
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle(String(localized: "多重曝光"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() }.disabled(working) }
            }
            .interactiveDismissDisabled(working)
        }
        .tint(Color.labRed)
        .presentationBackground(Color.labInk)
        // The two photographs, once each.
        .task {
            for id in [spec.bottom, spec.top] where frames[id] == nil {
                if let f = await model.doubleSourceFrame(id, longEdge: Self.previewEdge) { frames[id] = f }
            }
        }
        // The layers: once, and again when the pictures or the top's orientation change.
        .task(id: "\(spec.bottom)\(spec.top)\(frames.count)|\(spec.topTurns ?? 0)|\(spec.topMirrored == true)") {
            guard let bottom = frames[spec.bottom], let topFrame = frames[spec.top] else { return }
            let orientation = spec.topOrientation
            let made = await Task.detached(priority: .userInitiated) {
                DoubleComposer.layers(bottom: bottom, top: topFrame.applying(orientation))
            }.value
            guard !Task.isCancelled else { return }
            layers = made
            if let made { topSize = CGSize(width: made.topWidth, height: made.topHeight) }
        }
        // The preview, on the GPU, after each change: a few ms, so a drag follows the finger.
        .task(id: "\(layers != nil)\(topSize.width)|\(spec.balance)|\(spec.bottomEV)|\(spec.topEV)|\(spec.topPlace.cx)|\(spec.topPlace.cy)|\(spec.topPlace.zoom)") {
            guard let l = layers else { return }
            let s = spec
            let made = await Task.detached(priority: .userInitiated) { DoubleComposer.preview(l, spec: s) }.value
            guard !Task.isCancelled, let made else { return }
            picture = made
        }
    }

    /// The real composition; drag and pinch move the top through it.
    private var preview: some View {
        VStack(spacing: 6) {
            let b = frames[spec.bottom]
            let aspect = b.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
            GeometryReader { geo in
                let r = DoubleComposer.window(spec.topPlace, in: topSize == .zero ? CGSize(width: 1, height: 1) : topSize, aspect: aspect)
                ZStack {
                    Color.black
                    if let picture {
                        Image(decorative: picture, scale: 1).resizable().interpolation(.high)
                    } else {
                        ProgressView().tint(Color.labCream)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                // Drag and pinch as one gesture, both from where the touch began.
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .simultaneously(with: MagnifyGesture())
                        .onChanged { v in
                            let s = start ?? spec.topPlace
                            start = s
                            let t = v.first?.translation ?? .zero, m = v.second?.magnification ?? 1
                            // The picture follows the finger: points over the shown width of the top.
                            let sw = geo.size.width / max(r.width, 0.01), sh = geo.size.height / max(r.height, 0.01)
                            var p = s
                            p.zoom = s.zoom * m
                            p.cx = s.cx - t.width / sw
                            p.cy = s.cy - t.height / sh
                            spec.topPlace = DoubleComposer.clamped(p)
                        }
                        .onEnded { _ in start = nil }
                )
                .onTapGesture(count: 2) { spec.topPlace = PairPlacement() }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: 360, maxHeight: 400)
            Text(String(localized: "拖动摆放上层，双指缩放（可以缩到比画面小），双击恢复"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
