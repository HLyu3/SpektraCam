//  CropScreen.swift — the full-screen crop and straighten page.

import SwiftUI

struct CropScreen: View {
    let image: UIImage
    let onDone: (FrameCrop) -> Void
    let onCancel: () -> Void
    @State var crop: FrameCrop
    /// How the picture is shown turned, as Photos does it: a screen mirror (`flip`) of a clockwise turn (`spin`,
    /// degrees, summed so a turn animates the short way). Kept equal to the crop's turns and mirror
    /// (R^t·H = H·R^-t). Changing them here re-develops nothing until 完成.
    @State private var spin: Double
    @State private var flip: Bool
    /// A quarter turn animates as one rigid piece: the new layout is put in place at once, counter-turned and
    /// scaled to look like the old, and only this rotation and scale ease back to nothing.
    @State private var turnLag: Double = 0
    @State private var turnScale: CGFloat = 1
    @State private var stageArea: CGSize = .zero
    /// The picture with the keystone drawn in (the crop's turn and straighten are the stage's own); nil = none.
    @State private var keystoned: UIImage?
    /// The picture at most 1000 px, made once for those redraws.
    @State private var small: CGImage?
    /// 自动 running, and what it said when it found nothing.
    @State private var autoBusy = false
    @State private var autoNote: String?

    init(image: UIImage, onDone: @escaping (FrameCrop) -> Void, onCancel: @escaping () -> Void, crop: FrameCrop) {
        self.image = image; self.onDone = onDone; self.onCancel = onCancel
        _crop = State(initialValue: crop)
        let m = crop.mirrored == true
        _spin = State(initialValue: Double((m ? -crop.quarterTurns : crop.quarterTurns) * 90))
        _flip = State(initialValue: m)
    }

    /// A quarter turn on screen: the stage's sides swap.
    private var sideways: Bool { Int((spin / 90).rounded()) % 2 != 0 }
    /// The crop when a drag began, and which part of the box the finger holds.
    @State private var dragStart: (crop: FrameCrop, part: Part)?

    private enum Part { case move, topLeft, topRight, bottomLeft, bottomRight }

    private var source: CGSize { CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale) }

    var body: some View {
        content
            .overlay(alignment: .top) {
                if let autoNote {
                    Text(autoNote)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 64)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            // The keystoned picture, redrawn (small, off the main thread) as the sliders move.
            .task(id: "\(crop.keystoneV ?? 0)|\(crop.keystoneH ?? 0)") {
                var warp = FrameCrop(); warp.keystoneV = crop.keystoneV; warp.keystoneH = crop.keystoneH
                guard warp.hasKeystone else { keystoned = nil; return }
                // A moving slider: only the value it rests on for a moment is drawn.
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                if small == nil { small = image.cgImage.flatMap { Self.shrunk($0, to: 1000) } }
                guard let small else { return }
                let made = await Task.detached(priority: .userInitiated) {
                    warp.keystoned(small, space: CGColorSpace(name: CGColorSpace.displayP3)!)
                }.value
                if !Task.isCancelled, let made { keystoned = UIImage(cgImage: made) }
            }
    }

    /// `image` no longer than `edge` pixels.
    nonisolated private static func shrunk(_ image: CGImage, to edge: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > edge else { return image }
        let k = Double(edge) / Double(long)
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Button(String(localized: "取消"), action: onCancel)
                Spacer()
                Text(String(localized: "裁剪")).font(.headline)
                Spacer()
                Button(String(localized: "完成")) { onDone(crop) }.fontWeight(.semibold)
            }
            .foregroundStyle(Color.labCream)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            GeometryReader { proxy in
                let area = proxy.size
                let inner = sideways ? CGSize(width: area.height, height: area.width) : area
                stage(in: inner)
                    .rotationEffect(.degrees(spin + turnLag))
                    .scaleEffect(x: (flip ? -1 : 1) * turnScale, y: turnScale)
                    .frame(width: area.width, height: area.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if pinchStart == nil {
                                drag(start: toStage(g.startLocation, area: area, inner: inner),
                                     translation: toStage(g.translation), inner: inner)
                            }
                        }
                        .onEnded { _ in settle() })
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { g in pinch(g.magnification) }
                        .onEnded { _ in pinchStart = nil; settle() })
            }
            .clipped()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { stageArea = $0 }

            controls
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: the picture and the box
    //
    // As in Photos: the box sits still, filling the stage; drag moves the picture under it, pinch zooms it.
    // The corners still reshape the box; it grows back to fill the stage when the finger lifts.

    /// Source (view) pixel → stage point: `origin + p * s`. Held still while a finger is down.
    private struct Mapping { var s: CGFloat; var origin: CGPoint }
    @State private var frozen: Mapping?
    @State private var pinchStart: FrameCrop?

    private func fittedMapping(_ c: FrameCrop, in area: CGSize) -> Mapping {
        let box = c.rect(in: source)
        let inset: CGFloat = 24
        let s = min((area.width - 2 * inset) / box.width, (area.height - 2 * inset) / box.height)
        let view = CGSize(width: box.width * s, height: box.height * s)
        return Mapping(s: s, origin: CGPoint(x: (area.width - view.width) / 2 - box.minX * s,
                                             y: (area.height - view.height) / 2 - box.minY * s))
    }

    private func stage(in area: CGSize) -> some View {
        let m = frozen ?? fittedMapping(crop, in: area)
        let box = crop.rect(in: source)
        let viewBox = CGRect(x: m.origin.x + box.minX * m.s, y: m.origin.y + box.minY * m.s,
                             width: box.width * m.s, height: box.height * m.s)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: keystoned ?? image)
                .resizable()
                .frame(width: source.width * m.s, height: source.height * m.s)
                .rotationEffect(.degrees(crop.angle))
                .position(x: m.origin.x + source.width / 2 * m.s, y: m.origin.y + source.height / 2 * m.s)
            // Dim everything outside the box.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: area).insetBy(dx: -area.width, dy: -area.height))
                p.addRect(viewBox)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            grid(viewBox)
        }
        .frame(width: area.width, height: area.height)
        .allowsHitTesting(false)
    }

    /// A screen vector into the unturned stage: undo the mirror, then the turn.
    private func toStage(_ v: CGSize) -> CGSize {
        let x = flip ? -v.width : v.width, y = v.height
        let a = -spin * .pi / 180, c = cos(a), s = sin(a)
        return CGSize(width: x * c - y * s, height: x * s + y * c)
    }

    private func toStage(_ p: CGPoint, area: CGSize, inner: CGSize) -> CGPoint {
        let v = toStage(CGSize(width: p.x - area.width / 2, height: p.y - area.height / 2))
        return CGPoint(x: inner.width / 2 + v.width, y: inner.height / 2 + v.height)
    }

    private func turnLeft() {
        let d: Double = flip ? 90 : -90
        let area = stageArea
        func boxScale(sideways: Bool) -> CGFloat {
            let inner = sideways ? CGSize(width: area.height, height: area.width) : area
            return fittedMapping(crop, in: inner).s
        }
        let before = boxScale(sideways: sideways), after = boxScale(sideways: !sideways)
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still) {
            spin += d
            crop = crop.turned(-1)
            turnLag = -d
            turnScale = after > 0 ? before / after : 1
        }
        // The next update, so the counter-turn is drawn first and the ease starts from it.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) { turnLag = 0; turnScale = 1 }
        }
    }

    private func mirror() {
        withAnimation(.easeInOut(duration: 0.3)) {
            flip.toggle()
            crop = crop.flipped(vertically: false)
        }
    }

    private func settle() {
        dragStart = nil
        withAnimation(.easeOut(duration: 0.25)) { frozen = nil }
    }

    private func pinch(_ mag: CGFloat) {
        if pinchStart == nil { pinchStart = crop; dragStart = nil; frozen = nil }
        guard let start = pinchStart else { return }
        let floor = FrameCrop.minSide / max(start.width, start.height)
        let k = max(Double(1 / max(mag, 0.01)), floor)
        crop = zoomed(start, by: k)
    }

    /// `c` with its sides times `k` about its centre; zooming out past the picture's edge pulls the centre in,
    /// then stops at the largest box that fits.
    private func zoomed(_ c: FrameCrop, by k: Double) -> FrameCrop {
        func at(_ k: Double, pull t: Double) -> FrameCrop {
            var g = c
            g.width = c.width * k; g.height = c.height * k
            g.cx = c.cx + (0.5 - c.cx) * t; g.cy = c.cy + (0.5 - c.cy) * t
            return g
        }
        if at(k, pull: 0).fits(in: source) { return at(k, pull: 0) }
        if at(k, pull: 1).fits(in: source) {
            var lo = 0.0, hi = 1.0
            for _ in 0..<20 { let mid = (lo + hi) / 2; if at(k, pull: mid).fits(in: source) { hi = mid } else { lo = mid } }
            return at(k, pull: hi)
        }
        var lo = 1.0, hi = k                               // only zooming out gets here
        for _ in 0..<20 { let mid = (lo + hi) / 2; if at(mid, pull: 1).fits(in: source) { lo = mid } else { hi = mid } }
        return at(lo, pull: 1).fits(in: source) ? at(lo, pull: 1) : c
    }

    private func grid(_ r: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(dragStart == nil ? 0.25 : 0.5), lineWidth: 0.5)
            Path { $0.addRect(r) }.stroke(Color.white, lineWidth: 1.5)
            Path { p in
                let l: CGFloat = 18
                for (c, sx, sy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                    (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                    p.move(to: CGPoint(x: c.x + l * sx, y: c.y)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x, y: c.y + l * sy))
                }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .square))
        }
        .allowsHitTesting(false)
    }

    private func drag(start p: CGPoint, translation: CGSize, inner: CGSize) {
        let mapping = frozen ?? fittedMapping(crop, in: inner)
        let k = mapping.s
        if dragStart == nil {
            let r = crop.rect(in: source)
            let box = CGRect(x: mapping.origin.x + r.minX * k, y: mapping.origin.y + r.minY * k,
                             width: r.width * k, height: r.height * k)
            let reach: CGFloat = 36
            func near(_ c: CGPoint) -> Bool { hypot(p.x - c.x, p.y - c.y) < reach }
            let part: Part = near(CGPoint(x: box.minX, y: box.minY)) ? .topLeft
                : near(CGPoint(x: box.maxX, y: box.minY)) ? .topRight
                : near(CGPoint(x: box.minX, y: box.maxY)) ? .bottomLeft
                : near(CGPoint(x: box.maxX, y: box.maxY)) ? .bottomRight : .move
            dragStart = (crop, part)
            if part != .move { frozen = mapping }           // reshaping: the picture holds still, the box moves
        }
        guard let start = dragStart else { return }
        let d = CGSize(width: translation.width / k, height: translation.height / k)
        var r = start.crop.rect(in: source)
        switch start.part {
        case .move:
            r = r.offsetBy(dx: -d.width, dy: -d.height)      // the picture follows the finger
        default:
            // The opposite corner stays put.
            let left = start.part == .topLeft || start.part == .bottomLeft
            let top = start.part == .topLeft || start.part == .topRight
            let anchor = CGPoint(x: left ? r.maxX : r.minX, y: top ? r.maxY : r.minY)
            let minSide = FrameCrop.minSide * min(source.width, source.height)
            var w = max(minSide, (left ? r.maxX - (r.minX + d.width) : r.maxX + d.width - r.minX))
            var h = max(minSide, (top ? r.maxY - (r.minY + d.height) : r.maxY + d.height - r.minY))
            if let ratio = start.crop.ratio(source: source) {
                // Follow whichever side the finger moved more; the other keeps the ratio.
                if abs(d.width) * 1 >= abs(d.height) * ratio { h = w / ratio } else { w = h * ratio }
            }
            r = CGRect(x: left ? anchor.x - w : anchor.x, y: top ? anchor.y - h : anchor.y, width: w, height: h)
        }
        var next = start.crop
        next.setRect(r, in: source)
        if next.fits(in: source) {
            crop = next
        } else if start.part == .move {
            // Stop at the picture's edge and slide along it: the most of each axis's move that still fits.
            // (Keeping only the start's value on the blocked axis snapped the picture back where the drag began.)
            let r0 = start.crop.rect(in: source)
            func moved(_ dx: CGFloat, _ dy: CGFloat) -> FrameCrop {
                var c = start.crop; c.setRect(r0.offsetBy(dx: -dx, dy: -dy), in: source); return c
            }
            func most(_ fits: (CGFloat) -> Bool) -> CGFloat {
                if fits(1) { return 1 }
                var lo: CGFloat = 0, hi: CGFloat = 1
                for _ in 0..<16 { let mid = (lo + hi) / 2; if fits(mid) { lo = mid } else { hi = mid } }
                return lo
            }
            let tx = most { moved($0 * d.width, 0).fits(in: source) }
            let ty = most { moved(tx * d.width, $0 * d.height).fits(in: source) }
            crop = moved(tx * d.width, ty * d.height)
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Text(String(localized: "拉直")).font(.footnote)
                Spacer()
                Text(String(format: "%.1f°", shownAngle))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(crop.angle == 0 ? Color.secondary : Color.labCream)
                    .onTapGesture(count: 2) { setAngle(0) }
            }
            Slider(value: Binding(get: { shownAngle }, set: { setAngle((($0 * 10).rounded() / 10) * (flip ? -1 : 1)) }),
                   in: -FrameCrop.maxAngle...FrameCrop.maxAngle)
                .tint(Color.labRed)

            // Perspective: a building's converging verticals (垂直) or a wall seen from the side (水平) made square.
            // As seen: the stored keystones are in the photograph's own axes, the sliders in the screen's.
            let seen = shownKeystone
            keystoneRow(String(localized: "垂直透视"), value: seen.v) { setShownKeystone(h: seen.h, v: $0) }
            keystoneRow(String(localized: "水平透视"), value: seen.h) { setShownKeystone(h: $0, v: seen.v) }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(autoBusy ? String(localized: "正在找线…") : String(localized: "自动"), symbol: "wand.and.stars", on: false, action: autoUpright)
                        .disabled(autoBusy)
                    chip("", symbol: "rotate.left", on: false, action: turnLeft)
                    chip("", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", on: false, action: mirror)
                    ForEach(FrameCrop.Aspect.allCases) { a in
                        chip(a.title, on: crop.aspect == a) { setAspect(a, portrait: crop.portrait) }
                    }
                    // 横 / 竖 as seen: a quarter turn swaps them.
                    chip(crop.portrait != sideways ? String(localized: "竖") : String(localized: "横"), symbol: "rectangle.portrait.rotate", on: false) {
                        setAspect(crop.aspect, portrait: !crop.portrait)
                    }
                    .disabled(crop.aspect == .free || crop.aspect == .square)
                    .opacity(crop.aspect == .free || crop.aspect == .square ? 0.4 : 1)
                }
            }

            Button(String(localized: "重置")) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    crop = FrameCrop()
                    spin = (spin / 360).rounded() * 360; flip = false
                }
            }
                .font(.footnote)
                .foregroundStyle(crop.isIdentity ? Color.secondary : Color.labCream)
                .disabled(crop.isIdentity)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private func chip(_ title: String, symbol: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                if !title.isEmpty { Text(title) }
            }
            .font(.system(size: 12, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Color.black : Color.labCream)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(on ? Color.labCream : Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// One perspective slider; a double tap on the number sets it back to 0.
    private func keystoneRow(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.footnote).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set(($0 * 100).rounded() / 100) }), in: -1...1)
                .tint(Color.labRed)
            Text(String(format: "%+.0f", value * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == 0 ? Color.secondary : Color.labCream)
                .frame(width: 36, alignment: .trailing)
                .onTapGesture(count: 2) { set(0) }
        }
    }

    /// 自动: straighten and perspective from the picture's straight lines (`AutoUpright`), then the box fitted to it.
    private func autoUpright() {
        autoBusy = true
        let turns = crop.quarterTurns
        if small == nil { small = image.cgImage.flatMap { Self.shrunk($0, to: 1000) } }
        guard let picture = small else { autoBusy = false; return }
        Task {
            let fit = await Task.detached(priority: .userInitiated) { AutoUpright.fit(picture, turns: turns) }.value
            autoBusy = false
            guard let fit, fit.angle != 0 || fit.keystoneV != 0 || fit.keystoneH != 0 else {
                withAnimation { autoNote = fit == nil ? String(localized: "没找到可以对齐的直线") : String(localized: "已经是正的了") }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { autoNote = nil }
                return
            }
            var next = crop
            next.angle = fit.angle
            next.keystoneV = fit.keystoneV == 0 ? nil : fit.keystoneV
            next.keystoneH = fit.keystoneH == 0 ? nil : fit.keystoneH
            withAnimation(.easeOut(duration: 0.2)) { crop = next.fitted(in: source) }
        }
    }

    /// Quarter turns clockwise on screen, 0…3.
    private var screenTurns: Int { ((Int((spin / 90).rounded()) % 4) + 4) % 4 }

    /// The keystone vector (h, v) transforms like a point: d = 1 − k·p, so on screen k' = M·k (M = mirror · turn).
    private var shownKeystone: (h: Double, v: Double) {
        var (x, y) = (crop.keystoneH ?? 0, crop.keystoneV ?? 0)
        for _ in 0..<screenTurns { (x, y) = (-y, x) }
        return ((flip ? -x : x) + 0, y + 0)          // + 0: no "-0" on the label
    }

    private func setShownKeystone(h: Double, v: Double) {
        var (x, y) = (flip ? -h : h, v)
        for _ in 0..<screenTurns { (x, y) = (y, -x) }
        setKeystone(v: y, h: x)
    }

    private func setKeystone(v: Double, h: Double) {
        var next = crop
        next.keystoneV = abs(v) < 0.005 ? nil : v
        next.keystoneH = abs(h) < 0.005 ? nil : h
        crop = next.fitted(in: source)
    }

    private var shownAngle: Double { flip ? -crop.angle : crop.angle }

    private func setAngle(_ a: Double) {
        var next = crop
        next.angle = a
        crop = next.fitted(in: source)
    }

    /// The largest box of the new shape round the current centre that fits.
    private func setAspect(_ a: FrameCrop.Aspect, portrait: Bool) {
        var next = crop
        next.aspect = a
        next.portrait = portrait
        guard let ratio = next.ratio(source: source) else { crop = next; return }
        let w = min(source.width, source.height * ratio)
        next.setRect(CGRect(x: next.cx * source.width - w / 2, y: next.cy * source.height - w / ratio / 2,
                            width: w, height: w / ratio), in: source)
        crop = next.fitted(in: source)
    }
}
