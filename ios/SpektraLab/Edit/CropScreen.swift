//  CropScreen.swift — the full-screen crop and straighten page.

import SwiftUI

struct CropScreen: View {
    let image: UIImage
    let onDone: (FrameCrop) -> Void
    let onCancel: () -> Void
    @State var crop: FrameCrop
    /// The crop when a drag began, and which part of the box the finger holds.
    @State private var dragStart: (crop: FrameCrop, part: Part)?

    private enum Part { case move, topLeft, topRight, bottomLeft, bottomRight }

    private var source: CGSize { CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Text("裁剪").font(.headline)
                Spacer()
                Button("完成") { onDone(crop) }.fontWeight(.semibold)
            }
            .foregroundStyle(Color.labCream)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            GeometryReader { proxy in
                stage(in: proxy.size)
            }
            .padding(24)

            controls
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: the picture and the box

    private func stage(in area: CGSize) -> some View {
        let k = min(area.width / source.width, area.height / source.height)
        let shown = CGSize(width: source.width * k, height: source.height * k)
        let box = crop.rect(in: source)
        let viewBox = CGRect(x: box.minX * k, y: box.minY * k, width: box.width * k, height: box.height * k)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: shown.width, height: shown.height)
                .rotationEffect(.degrees(crop.angle))
            // Dim everything outside the box.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: shown).insetBy(dx: -area.width, dy: -area.height))
                p.addRect(viewBox)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            grid(viewBox)
        }
        .frame(width: shown.width, height: shown.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in drag(g, scale: k, box: viewBox) }
            .onEnded { _ in dragStart = nil })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func drag(_ g: DragGesture.Value, scale k: CGFloat, box: CGRect) {
        if dragStart == nil {
            let p = g.startLocation, reach: CGFloat = 36
            func near(_ c: CGPoint) -> Bool { hypot(p.x - c.x, p.y - c.y) < reach }
            let part: Part = near(CGPoint(x: box.minX, y: box.minY)) ? .topLeft
                : near(CGPoint(x: box.maxX, y: box.minY)) ? .topRight
                : near(CGPoint(x: box.minX, y: box.maxY)) ? .bottomLeft
                : near(CGPoint(x: box.maxX, y: box.maxY)) ? .bottomRight : .move
            dragStart = (crop, part)
        }
        guard let start = dragStart else { return }
        let d = CGSize(width: g.translation.width / k, height: g.translation.height / k)
        var r = start.crop.rect(in: source)
        switch start.part {
        case .move:
            r = r.offsetBy(dx: d.width, dy: d.height)
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
            // Slide along the edge rather than stop dead: keep whichever axis still fits.
            var xOnly = start.crop; xOnly.cx = next.cx
            var yOnly = start.crop; yOnly.cy = next.cy
            if xOnly.fits(in: source) { crop = xOnly } else if yOnly.fits(in: source) { crop = yOnly }
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Text("拉直").font(.footnote)
                Spacer()
                Text(String(format: "%.1f°", crop.angle))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(crop.angle == 0 ? Color.secondary : Color.labCream)
                    .onTapGesture(count: 2) { setAngle(0) }
            }
            Slider(value: Binding(get: { crop.angle }, set: { setAngle(($0 * 10).rounded() / 10) }),
                   in: -FrameCrop.maxAngle...FrameCrop.maxAngle)
                .tint(Color.labRed)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FrameCrop.Aspect.allCases) { a in
                        chip(a.title, on: crop.aspect == a) { setAspect(a, portrait: crop.portrait) }
                    }
                    chip(crop.portrait ? "竖" : "横", symbol: "rotate.right", on: false) {
                        setAspect(crop.aspect, portrait: !crop.portrait)
                    }
                    .disabled(crop.aspect == .free || crop.aspect == .square)
                    .opacity(crop.aspect == .free || crop.aspect == .square ? 0.4 : 1)
                }
            }

            Button("重置") { crop = FrameCrop() }
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
                Text(title)
            }
            .font(.system(size: 12, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Color.black : Color.labCream)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(on ? Color.labCream : Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

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
