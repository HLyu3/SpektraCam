//  HalfFramePair.swift — two photographs side by side on one piece of 135 film.
//
//  A trimmed take on upstream `Model/HalfFramePair.swift`: two 18 × 24 mm holes
//  side by side, 1 mm of unexposed base between them, each picture centred in
//  its hole and metered on its own. The piece is composed once, in the decoder's
//  linear ProPhoto, and kept as a 10-bit HEIF original, so the rest of the app
//  (film, paper, film edge, 后期, export) treats it as one photograph.
//  shortcut: no per-hole placement, turned (vertical) pairs or per-hole enlarger; add them from upstream if wanted.

import CoreGraphics
import CoreImage
import Foundation
import UniformTypeIdentifiers

struct PairSpec: Codable, Equatable, Sendable, Identifiable {
    var id: String { left.uuidString + right.uuidString }
    var left: UUID
    var right: UUID
    /// Stops on top of each picture's own meter.
    var leftEV = 0.0
    var rightEV = 0.0
    /// Which part of each picture fills its hole.
    var leftPlace = PairPlacement()
    var rightPlace = PairPlacement()

    var swapped: PairSpec {
        PairSpec(left: right, right: left, leftEV: rightEV, rightEV: leftEV, leftPlace: rightPlace, rightPlace: leftPlace)
    }
}

/// A hole's window on its picture: centre (fractions of the upright picture) and zoom (1 = the
/// largest 18 × 24 window that fits).
struct PairPlacement: Codable, Equatable, Sendable {
    var cx = 0.5, cy = 0.5
    var zoom = 1.0
    static let maxZoom = 4.0
}

enum PairComposer {
    /// One hole, width over height (18 × 24 mm, the frame upright).
    static let holeAspect: CGFloat = 18.0 / 24.0
    /// Unexposed base between the holes, as a fraction of the hole's height (1 mm of 24).
    static let gapFraction = 1.0 / 24.0
    /// The meter pulls each picture's log-average luminance to mid grey, within this many stops.
    static let meterRange = -3.0...3.0

    /// The window `place` cuts from a picture of `size` (upright), in fractions of it, kept inside it.
    static func window(_ place: PairPlacement, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let fitH = size.width / size.height > holeAspect ? size.height : size.width / holeAspect
        let z = min(max(place.zoom, 1), PairPlacement.maxZoom)
        let w = fitH * holeAspect / z / size.width, h = fitH / z / size.height
        let x = min(max(place.cx - w / 2, 0), 1 - w), y = min(max(place.cy - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// `place` with its centre pulled back inside the picture (what `window` would use).
    static func clamped(_ place: PairPlacement, in size: CGSize) -> PairPlacement {
        let r = window(place, in: size)
        var p = place
        p.zoom = min(max(place.zoom, 1), PairPlacement.maxZoom)
        p.cx = r.midX; p.cy = r.midY
        return p
    }

    /// Stops that bring this picture's log-average luminance (linear ProPhoto Y) to 18 %.
    static func meter(_ frame: DecodedFrame) -> Double {
        let n = frame.width * frame.height
        guard n > 0 else { return 0 }
        let step = max(1, Int((Double(n) / 40_000).squareRoot()))
        var sum = 0.0, count = 0.0
        frame.pixels.withUnsafeBufferPointer { p in
            var y = 0
            while y < frame.height {
                var x = 0
                while x < frame.width {
                    let i = (y * frame.width + x) * 3
                    let lum = 0.2880402 * Double(p[i]) + 0.7118741 * Double(p[i + 1]) + 0.0000857 * Double(p[i + 2])
                    sum += log(max(lum, 1e-5)); count += 1
                    x += step
                }
                y += step
            }
        }
        let ev = log2(0.18) - sum / max(count, 1) / log(2)
        return min(max(ev, meterRange.lowerBound), meterRange.upperBound)
    }

    /// `frame` scaled (bilinear) to `height`, keeping its aspect. For a hole smaller than its neighbour:
    /// it gains no detail, but the larger picture keeps all of its own.
    static func scaled(_ frame: DecodedFrame, toHeight height: Int) -> DecodedFrame {
        guard frame.height != height, frame.height > 1, frame.width > 1 else { return frame }
        let k = Double(height) / Double(frame.height)
        let w = max(1, Int((Double(frame.width) * k).rounded())), sw = frame.width, sh = frame.height
        var out = [Float](repeating: 0, count: w * height * 3)
        frame.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let fy = min(max((Double(y) + 0.5) / k - 0.5, 0), Double(sh - 1))
                    let y0 = Int(fy), y1 = min(y0 + 1, sh - 1), ty = Float(fy - Double(y0))
                    for x in 0..<w {
                        let fx = min(max((Double(x) + 0.5) / k - 0.5, 0), Double(sw - 1))
                        let x0 = Int(fx), x1 = min(x0 + 1, sw - 1), tx = Float(fx - Double(x0))
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
        return DecodedFrame(pixels: FloatRGBPixels(out), width: w, height: height)
    }

    /// The piece: `left` and `right` side by side with the gap, each multiplied by its gain.
    /// The taller hole sets the height; the other is scaled up to it.
    static func compose(_ left: DecodedFrame, _ right: DecodedFrame, gains: (Float, Float)) -> DecodedFrame {
        let h = max(left.height, right.height)
        let left = scaled(left, toHeight: h), right = scaled(right, toHeight: h)
        let gap = max(1, Int((Double(h) * gapFraction).rounded()))
        let w = left.width + gap + right.width
        var out = [Float](repeating: 0, count: w * h * 3)
        out.withUnsafeMutableBufferPointer { dst in
            for (frame, x0, gain) in [(left, 0, gains.0), (right, left.width + gap, gains.1)] {
                frame.pixels.withUnsafeBufferPointer { src in
                    for row in 0..<h {
                        let from = row * frame.width * 3, to = (row * w + x0) * 3
                        for k in 0..<(frame.width * 3) { dst[to + k] = src[from + k] * gain }
                    }
                }
            }
        }
        return DecodedFrame(pixels: FloatRGBPixels(out), width: w, height: h)
    }

    /// The piece as a 10-bit HEIF in ProPhoto, which `ImageDecoder` reads back into linear ProPhoto.
    static func heif(_ piece: DecodedFrame) throws -> Data {
        guard let linear = ImageDecoder.linearProPhoto,
              let proPhoto = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw DecodeError.unreadable("ProPhoto RGB is unavailable")
        }
        let n = piece.width * piece.height
        var rgba = [Float16](repeating: 1, count: n * 4)
        piece.pixels.withUnsafeBufferPointer { p in
            for i in 0..<n {
                rgba[i * 4] = Float16(p[i * 3]); rgba[i * 4 + 1] = Float16(p[i * 3 + 1]); rgba[i * 4 + 2] = Float16(p[i * 3 + 2])
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: piece.width * 8,
                            size: CGSize(width: piece.width, height: piece.height),
                            format: .RGBAh, colorSpace: linear)
        let context = CIContext(options: [.cacheIntermediates: false])
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return try context.heif10Representation(of: image, colorSpace: proPhoto, options: [quality: 0.95])
    }
}

import SwiftUI

/// Choose the order and each picture's exposure, then compose the pair.
struct PairSheet: View {
    @ObservedObject var model: ViewModel
    @State var spec: PairSpec
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    private func photo(_ id: UUID) -> LibraryPhoto? { model.library.first { $0.id == id } }

    /// A picture whose own hole would be far smaller than its neighbour's is scaled up and looks soft.
    private var lowResolutionNote: String? {
        guard let l = photo(spec.left), let r = photo(spec.right) else { return nil }
        let a = max(l.pixelWidth, l.pixelHeight), b = max(r.pixelWidth, r.pixelHeight)
        guard min(a, b) * 2 < max(a, b) else { return nil }
        let small = a < b ? l : r
        return String(localized: "「\(small.name)」只有 \(small.pixelWidth)×\(small.pixelHeight)，会被放大到另一张的尺寸，这一格会偏软。")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                preview
                    .padding(.top, 8)
                Button {
                    spec = spec.swapped
                } label: {
                    Label(String(localized: "左右互换"), systemImage: "arrow.left.arrow.right")
                        .font(.footnote.weight(.semibold))
                }
                VStack(spacing: 10) {
                    FinishSlider(title: String(localized: "左格曝光"), value: $spec.leftEV, range: -2...2,
                                 text: { String(format: "%+.1f EV", $0) })
                    FinishSlider(title: String(localized: "右格曝光"), value: $spec.rightEV, range: -2...2,
                                 text: { String(format: "%+.1f EV", $0) })
                    if let small = lowResolutionNote {
                        Text(small)
                            .font(.caption2)
                            .foregroundStyle(Color.labRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(String(localized: "两格各自测光，先拉到中灰，这里再各自加减。双击标题归零。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Button {
                    working = true
                    Task {
                        let made = await model.makePair(spec)
                        working = false
                        if made != nil { done(); dismiss() }
                    }
                } label: {
                    HStack {
                        if working { ProgressView().tint(.white) }
                        Text(working ? String(localized: "正在合成…") : String(localized: "生成双拼"))
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.labRed, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
            .padding(20)
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle(String(localized: "半格双拼"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() }.disabled(working) }
            }
            .interactiveDismissDisabled(working)
        }
        .tint(Color.labRed)
        .presentationBackground(Color.labInk)
    }

    /// The two holes from the wall thumbnails, each brightened by its meter and its stops.
    private var preview: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                if let l = photo(spec.left) { PairHoleView(photo: l, place: $spec.leftPlace, ev: spec.leftEV) }
                if let r = photo(spec.right) { PairHoleView(photo: r, place: $spec.rightPlace, ev: spec.rightEV) }
            }
            .padding(4)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: 340)
            Text(String(localized: "拖动选取画面，双指缩放取局部，双击恢复整幅"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// One hole: the picture under it, moved with a finger and zoomed with two.
struct PairHoleView: View {
    let photo: LibraryPhoto
    @Binding var place: PairPlacement
    let ev: Double
    @State private var start: PairPlacement?

    var body: some View {
        GeometryReader { geo in
            let image = photo.thumbnail.size
            let r = PairComposer.window(place, in: image)
            let shown = CGSize(width: geo.size.width / r.width, height: geo.size.height / r.height)
            Image(uiImage: photo.thumbnail)
                .resizable()
                .frame(width: shown.width, height: shown.height)
                .offset(x: -r.minX * shown.width, y: -r.minY * shown.height)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                // A rough stand-in for the stops; the real meter runs on the full pictures.
                .overlay(Color.white.opacity(max(0, ev) * 0.12))
                .overlay(Color.black.opacity(max(0, -ev) * 0.2))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { g in
                            let s = start ?? place
                            start = s
                            var p = s
                            p.cx -= g.translation.width / shown.width
                            p.cy -= g.translation.height / shown.height
                            place = PairComposer.clamped(p, in: image)
                        }
                        .onEnded { _ in start = nil }
                        .simultaneously(with: MagnifyGesture()
                            .onChanged { g in
                                let s = start ?? place
                                start = s
                                var p = s
                                p.zoom = s.zoom * g.magnification
                                place = PairComposer.clamped(p, in: image)
                            }
                            .onEnded { _ in start = nil })
                )
                .onTapGesture(count: 2) { place = PairPlacement() }
        }
        .aspectRatio(PairComposer.holeAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }
}
