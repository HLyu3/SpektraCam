//  LocalAdjust.swift — 局部调整: a graduated or radial mask with its own light and colour, over the finish (Layer 2).
//
//  Upstream's local layers (Layer2Local, MaskBaker, …: subject masks, brushes, per-pixel control fields, ~3,000 lines)
//  are not ported. This is the plain darkroom version: each layer runs the finish pass again with its offsets added to
//  the whole picture's (`Adjustments.adding`) and is blended over it by its mask — `out = whole + (layer − whole)·m`,
//  the mask drawn analytically on the GPU (no plane to bake or keep). A half-covered pixel is the mix of the two
//  results rather than the control at half its amount; for the soft masks here the difference does not show.
//  The masks are in the finished picture's own fractions (the engine's print, the crop and turns already in it), so the
//  preview, the thumbnails and the full-size export all place them alike.

import Foundation
import Metal
import SwiftUI
import Vision

struct LocalAdjustment: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// subject / person: a mask Vision finds in the picture itself (`SubjectMasks`); 反向 turns it into the background.
    enum Kind: String, Codable, Sendable { case linear, radial, subject, person }

    var id = UUID()
    var kind: Kind = .linear
    /// Linear: full effect at (x0, y0), none at (x1, y1) — fractions of the picture's width and height.
    var x0 = 0.5, y0 = 0.15, x1 = 0.5, y1 = 0.55
    /// Radial: centre and radii (fractions of width / height), and the soft edge's share of the radius (0…1).
    var cx = 0.5, cy = 0.5, rx = 0.3, ry = 0.3, feather = 0.5
    /// The effect outside the shape instead of inside it.
    var inverted = false
    /// Offsets in `Adjustments`' own units.
    var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0
    var temperature = 0.0, tint = 0.0, saturation = 0.0

    static let maxPerPhoto = 4

    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0 && temperature == 0 && tint == 0 && saturation == 0
    }

    /// The sliders: key path, title, range, step.
    nonisolated(unsafe) static let controls: [(WritableKeyPath<LocalAdjustment, Double>, String, ClosedRange<Double>, Double)] = [
        (\.exposure, String(localized: "曝光"), -3...3, 0.05),
        (\.contrast, String(localized: "对比度"), -50...50, 1),
        (\.highlights, String(localized: "高光"), -100...100, 1),
        (\.shadows, String(localized: "阴影"), -100...100, 1),
        (\.temperature, String(localized: "色温"), -100...100, 1),
        (\.tint, String(localized: "色调"), -100...100, 1),
        (\.saturation, String(localized: "饱和度"), -100...100, 1),
    ]
}

extension Adjustments {
    /// The whole picture's look with a layer's offsets on top, each held to its control's range.
    func adding(_ l: LocalAdjustment) -> Adjustments {
        var a = self
        a.enabled = true
        a.exposure = min(max(a.exposure + l.exposure, -5), 5)
        a.contrast = min(max(a.contrast + l.contrast, -100), 100)
        a.highlights = min(max(a.highlights + l.highlights, -100), 100)
        a.shadows = min(max(a.shadows + l.shadows, -100), 100)
        a.temperature = min(max(a.temperature + l.temperature, -100), 100)
        a.tint = min(max(a.tint + l.tint, -100), 100)
        a.saturation = min(max(a.saturation + l.saturation, -100), 100)
        return a
    }
}

/// The blend of one layer's pass over the whole picture's, through its mask.
final class LocalBlend: @unchecked Sendable {
    static let shared: LocalBlend? = Layer2Renderer.shared.flatMap { try? LocalBlend(device: $0.device) }

    private let queue: MTLCommandQueue
    private let pass: MTLComputePipelineState

    /// The mask's numbers as the kernel reads them.
    private struct Mask {
        var kind: Int32; var inverted: Int32; var size: SIMD2<UInt32>
        var a: SIMD4<Float>     // linear: x0 y0 x1 y1 · radial: cx cy rx ry
        var b: SIMD4<Float>     // radial: feather
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Mask { int kind; int inverted; uint2 size; float4 a; float4 b; };
    kernel void spkLocalBlend(device ushort4* whole [[buffer(0)]], device const ushort4* layer [[buffer(1)]],
                              constant Mask& m [[buffer(2)]], texture2d<float> found [[texture(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= m.size.x || gid.y >= m.size.y) return;
        float2 p = (float2(gid) + 0.5) / float2(m.size);
        float k;
        if (m.kind == 0) {
            float2 d = m.a.zw - m.a.xy;
            float t = dot(p - m.a.xy, d) / max(dot(d, d), 1e-6);
            k = 1.0 - smoothstep(0.0, 1.0, t);
        } else if (m.kind == 2) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            k = found.sample(s, p, level(0)).r;
        } else {
            float r = length((p - m.a.xy) / max(m.a.zw, float2(1e-4)));
            float f = clamp(m.b.x, 0.01, 1.0);
            k = 1.0 - smoothstep(1.0 - f, 1.0, r);
        }
        if (m.inverted != 0) k = 1.0 - k;
        if (k <= 0.0) return;
        uint i = gid.y * m.size.x + gid.x;
        float4 w = float4(whole[i]), l = float4(layer[i]);
        whole[i] = ushort4(clamp(w + (l - w) * k, 0.0, 65535.0) + 0.5);
    }
    """

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw Layer2Renderer.Failure.gpu("no command queue for local layers") }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let f = library.makeFunction(name: "spkLocalBlend") else { throw Layer2Renderer.Failure.gpu("spkLocalBlend is missing") }
        pass = try device.makeComputePipelineState(function: f)
        masks = SubjectMasks(device: device)
    }

    private let masks: SubjectMasks

    /// `source`'s subject / person mask as red with the mask's strength for alpha, at Vision's resolution.
    func overlay(_ source: Layer2Source, person: Bool) -> CGImage? {
        guard let t = masks.mask(source, person: person), t.width > 1 else { return nil }
        let (w, h) = (t.width, t.height)
        var values = [Float](repeating: 0, count: w * h)
        values.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = UInt8(min(max(values[i], 0), 1) * 140)   // premultiplied red at ≤ 55 %
            rgba[i * 4] = a; rgba[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// `layer` blended into `whole` (both the finish pass's RGBA16 buffers, `width` × `height`) through `l`'s mask.
    /// `source` is what the pass ran on — where a subject / person mask is looked for.
    func blend(_ layer: MTLBuffer, into whole: MTLBuffer, source: Layer2Source, _ l: LocalAdjustment) throws {
        let (width, height) = (source.width, source.height)
        let found: MTLTexture? = switch l.kind {
        case .subject, .person: masks.mask(source, person: l.kind == .person)
        default: nil
        }
        var m = Mask(kind: found != nil ? 2 : l.kind == .linear ? 0 : 1, inverted: l.inverted ? 1 : 0,
                     size: SIMD2(UInt32(width), UInt32(height)),
                     a: l.kind == .linear ? SIMD4(Float(l.x0), Float(l.y0), Float(l.x1), Float(l.y1))
                                          : SIMD4(Float(l.cx), Float(l.cy), Float(l.rx), Float(l.ry)),
                     b: SIMD4(Float(l.feather), 0, 0, 0))
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw Layer2Renderer.Failure.gpu("the local blend could not be encoded")
        }
        encoder.setComputePipelineState(pass)
        encoder.setBuffer(whole, offset: 0, index: 0)
        encoder.setBuffer(layer, offset: 0, index: 1)
        encoder.setBytes(&m, length: MemoryLayout<Mask>.stride, index: 2)
        encoder.setTexture(found ?? masks.empty, index: 0)
        let tw = pass.threadExecutionWidth, th = max(1, pass.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw Layer2Renderer.Failure.gpu("the local blend failed: \(error.localizedDescription)") }
    }
}

private extension View {
    /// 反向: the red where the mask is NOT — red everywhere, cut out by the mask.
    @ViewBuilder func colorInvertedMask(_ inverted: Bool, size: CGSize) -> some View {
        if inverted {
            Color.red.opacity(0.55).frame(width: size.width, height: size.height)
                .mask { ZStack { Color.white; self.blendMode(.destinationOut) }.compositingGroup() }
        } else {
            self
        }
    }
}

// MARK: - masks Vision finds

/// The subject or the people in a picture as a soft mask texture (r32Float, at Vision's own resolution, sampled
/// bilinearly by the blend). Found once per picture: keyed by its size and a sample of its pixels, so slider moves over
/// the same source hit the cache while the export's full-size source gets its own. Nothing found → an empty mask.
final class SubjectMasks: @unchecked Sendable {
    private let device: MTLDevice
    let empty: MTLTexture
    private let lock = NSLock()
    private var cache: [(key: Int, texture: MTLTexture)] = []

    init(device: MTLDevice) {
        self.device = device
        empty = Self.texture(device, [0], width: 1, height: 1)!
    }

    func mask(_ source: Layer2Source, person: Bool) -> MTLTexture? {
        let key = Self.key(source, person: person)
        lock.lock()
        if let hit = cache.first(where: { $0.key == key }) { lock.unlock(); return hit.texture }
        lock.unlock()
        let found = Self.find(source, person: person, device: device) ?? empty
        lock.lock()
        cache.append((key, found))
        if cache.count > 6 { cache.removeFirst() }
        lock.unlock()
        return found
    }

    private static func key(_ source: Layer2Source, person: Bool) -> Int {
        var h = Hasher()
        h.combine(source.width); h.combine(source.height); h.combine(person)
        let px = source.buffer.contents().assumingMemoryBound(to: UInt64.self), n = source.width * source.height
        for i in 0..<256 { h.combine(px[(i &* 7_919 &+ i * n / 256) % n]) }
        return h.finalize()
    }

    /// Vision on an 8-bit copy at ≤ 1024 px (its models run smaller anyway; a 25 MP 16-bit hand-over would cost memory
    /// the export has not got).
    private static func find(_ source: Layer2Source, person: Bool, device: MTLDevice) -> MTLTexture? {
        let scale = min(1, 1024 / Double(max(source.width, source.height)))
        let w = max(1, Int(Double(source.width) * scale)), h = max(1, Int(Double(source.height) * scale))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(dataInfo: nil, data: source.buffer.contents(), size: source.bytes,
                                            releaseData: { _, _, _ in }),
              let full = CGImage(width: source.width, height: source.height, bitsPerComponent: 16, bitsPerPixel: 64,
                                 bytesPerRow: source.width * 8, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue
                                                          | CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let handler = VNImageRequestHandler(cgImage: small)
        let started = Date()
        defer { NSLog("SpektraLab mask %@ %dx%d %.0f ms", person ? "person" : "subject", w, h, Date().timeIntervalSince(started) * 1000) }
        do {
            let buffer: CVPixelBuffer?
            if person {
                let r = VNGeneratePersonSegmentationRequest()
                r.qualityLevel = .accurate
                r.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
                try handler.perform([r])
                buffer = r.results?.first?.pixelBuffer
            } else {
                let r = VNGenerateForegroundInstanceMaskRequest()
                try handler.perform([r])
                if let o = r.results?.first { buffer = try o.generateMask(forInstances: o.allInstances) } else { buffer = nil }
            }
            guard let buffer else { return nil }
            return floatTexture(buffer, device: device)
        } catch {
            NSLog("SpektraLab mask failed: %@", "\(error)")
            return nil
        }
    }

    private static func floatTexture(_ b: CVPixelBuffer, device: MTLDevice) -> MTLTexture? {
        guard CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b), row = CVPixelBufferGetBytesPerRow(b)
        guard let base = CVPixelBufferGetBaseAddress(b) else { return nil }
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let line = (base + y * row).assumingMemoryBound(to: Float.self)
            for x in 0..<w { values[y * w + x] = min(max(line[x], 0), 1) }
        }
        return texture(device, values, width: w, height: h)
    }

    private static func texture(_ device: MTLDevice, _ values: [Float], width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        values.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                           withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return t
    }
}

// MARK: - the 局部 panel

struct LocalPanel: View {
    @ObservedObject var model: ViewModel

    private var layers: [LocalAdjustment] { model.recipe.localAdjustments ?? [] }
    private var current: LocalAdjustment? { layers.first { $0.id == model.selectedLocal } ?? layers.last }

    var body: some View {
        ToolScroll {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        add(String(localized: "渐变"), "square.bottomhalf.filled", .linear)
                        add(String(localized: "径向"), "circle.dashed", .radial)
                        add(String(localized: "主体"), "person.and.background.dotted", .subject)
                        add(String(localized: "人物"), "person.fill", .person)
                    }
                }
                if layers.count > 1, let c = current {
                    Picker("", selection: Binding(get: { c.id }, set: { model.selectedLocal = $0 })) {
                        ForEach(Array(layers.enumerated()), id: \.element.id) { i, l in
                            Text(String(localized: "局部 \(i + 1)")).tag(l.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if let c = current {
                Text(hint(c.kind))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(LocalAdjustment.controls.enumerated()), id: \.offset) { _, control in
                    let (path, title, range, step) = control
                    FinishSlider(title: title, value: Binding(get: { c[keyPath: path] }, set: { v in
                        var q = c; q[keyPath: path] = (v / step).rounded() * step; update(q)
                    }), range: range, text: { step < 1 ? Fmt.signed($0, decimals: 2) : Fmt.signed($0, decimals: 0) })
                }
                if c.kind == .radial {
                    FinishSlider(title: String(localized: "羽化"), value: Binding(get: { c.feather * 100 }, set: { v in
                        var q = c; q.feather = min(max(v.rounded() / 100, 0.02), 1); update(q)
                    }), range: 2...100, rest: 50, text: { String(format: "%.0f", $0) })
                }
                HStack {
                    Toggle(String(localized: "反向"), isOn: Binding(get: { c.inverted }, set: { var q = c; q.inverted = $0; update(q) }))
                        .toggleStyle(.button).tint(Color.labRed)
                    if c.kind == .subject || c.kind == .person {
                        Button { model.localMaskFlash += 1 } label: { Label(String(localized: "显示范围"), systemImage: "eye") }
                            .buttonStyle(.bordered).tint(Color.labRed)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        model.edit { r in r.localAdjustments = (r.localAdjustments ?? []).filter { $0.id != c.id } }
                        model.selectedLocal = nil
                    } label: { Label(String(localized: "删除这个局部"), systemImage: "trash") }
                }
                .font(.footnote)
            } else {
                Note(String(localized: "加一个渐变、径向、主体或人物遮罩，只调照片的一部分：比如压暗天空、提亮人脸。最多 4 个。"))
            }
        }
    }

    private func hint(_ kind: LocalAdjustment.Kind) -> String {
        switch kind {
        case .linear: String(localized: "在照片上拖两个圆点：实心点一端是全部效果，空心点一端没有效果。")
        case .radial: String(localized: "在照片上拖中心移动，拖右边和下边的圆点改大小。")
        case .subject: String(localized: "自动找出照片里的主体（人、动物、物件）。打开「反向」就是只调背景。")
        case .person: String(localized: "自动找出照片里的人，连头发边缘。打开「反向」就是只调人以外的部分。")
        }
    }

    private func add(_ title: String, _ symbol: String, _ kind: LocalAdjustment.Kind) -> some View {
        Button {
            guard layers.count < LocalAdjustment.maxPerPhoto else {
                model.libraryMessage = String(localized: "一张照片最多 \(LocalAdjustment.maxPerPhoto) 个局部调整")
                return
            }
            var l = LocalAdjustment(); l.kind = kind
            model.edit { r in r.localAdjustments = (r.localAdjustments ?? []) + [l] }
            model.selectedLocal = l.id
        } label: {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).frame(height: 32)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func update(_ l: LocalAdjustment) {
        model.edit { r in
            var list = r.localAdjustments ?? []
            if let i = list.firstIndex(where: { $0.id == l.id }) { list[i] = l }
            r.localAdjustments = list
        }
    }
}

// MARK: - handles on the picture

/// The chosen layer's shape over the picture (aspect-fit in `area`), with handles to drag while the 局部 tool is open.
struct LocalOverlay: View {
    @ObservedObject var model: ViewModel
    let picture: CGSize
    let area: CGSize
    @State private var start: LocalAdjustment?
    @State private var found: (key: String, image: CGImage?)?
    /// The red shows for a moment (found, or 显示范围 tapped) and fades, so the adjustment itself can be seen.
    @State private var tinted = false
    @State private var tintTask: Task<Void, Never>?

    var body: some View {
        let k = min(area.width / max(picture.width, 1), area.height / max(picture.height, 1))
        let shown = CGSize(width: picture.width * k, height: picture.height * k)
        let layers = model.recipe.localAdjustments ?? []
        ZStack(alignment: .topLeading) {
            if let l = layers.first(where: { $0.id == model.selectedLocal }) ?? layers.last {
                switch l.kind {
                case .linear: linear(l, shown)
                case .radial: radial(l, shown)
                case .subject, .person: foundMask(l, shown)
                }
            }
        }
        .frame(width: shown.width, height: shown.height)
        .frame(width: area.width, height: area.height)
    }

    /// The found mask tinted red where the layer acts (flipped with 反向), hidden by 显示范围 off.
    @ViewBuilder private func foundMask(_ l: LocalAdjustment, _ s: CGSize) -> some View {
        let key = "\(l.kind.rawValue)|\(Int(picture.width))x\(Int(picture.height))"
        Group {
            if let f = found, f.key == key {
                if tinted, let image = f.image {
                    Image(decorative: image, scale: 1)
                        .resizable().frame(width: s.width, height: s.height)
                        .colorInvertedMask(l.inverted, size: s)
                } else if f.image == nil {
                    Text(l.kind == .person ? String(localized: "没找到人") : String(localized: "没找到主体"))
                        .font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                        .frame(width: s.width, height: s.height)
                }
            } else {
                ProgressView().frame(width: s.width, height: s.height)
            }
        }
        .allowsHitTesting(false)
        .task(id: key) {
            let image = await model.localMaskImage(person: l.kind == .person)
            found = (key, image)
            flash()
        }
        .onChange(of: model.localMaskFlash) { flash() }
        .onChange(of: l.id) { flash() }
        .onChange(of: l.inverted) { flash() }
    }

    private func flash() {
        tintTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { tinted = true }
        tintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { tinted = false }
        }
    }

    private func pt(_ x: Double, _ y: Double, _ s: CGSize) -> CGPoint { CGPoint(x: x * s.width, y: y * s.height) }

    private func linear(_ l: LocalAdjustment, _ s: CGSize) -> some View {
        let a = pt(l.x0, l.y0, s), b = pt(l.x1, l.y1, s)
        return ZStack(alignment: .topLeading) {
            // The two edges of the ramp, square to the line between the handles.
            ForEach([a, b], id: \.x) { p in edgeLine(through: p, along: CGPoint(x: b.x - a.x, y: b.y - a.y), s) }
            Path { $0.move(to: a); $0.addLine(to: b) }.stroke(Color.labRed.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            handle(at: a, filled: true) { d in moved(l, d, s) { q, dx, dy in q.x0 += dx; q.y0 += dy } }
            handle(at: b, filled: false) { d in moved(l, d, s) { q, dx, dy in q.x1 += dx; q.y1 += dy } }
        }
    }

    private func edgeLine(through p: CGPoint, along d: CGPoint, _ s: CGSize) -> some View {
        let len = max(hypot(d.x, d.y), 1), n = CGPoint(x: -d.y / len, y: d.x / len), r = hypot(s.width, s.height)
        return Path { $0.move(to: CGPoint(x: p.x - n.x * r, y: p.y - n.y * r)); $0.addLine(to: CGPoint(x: p.x + n.x * r, y: p.y + n.y * r)) }
            .stroke(Color.white.opacity(0.75), lineWidth: 1)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .allowsHitTesting(false)
    }

    private func radial(_ l: LocalAdjustment, _ s: CGSize) -> some View {
        let c = pt(l.cx, l.cy, s), rx = l.rx * s.width, ry = l.ry * s.height
        return ZStack(alignment: .topLeading) {
            Ellipse().stroke(Color.white.opacity(0.8), lineWidth: 1.2)
                .frame(width: 2 * rx, height: 2 * ry).position(c).allowsHitTesting(false)
            Ellipse().stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(width: 2 * rx * (1 - l.feather), height: 2 * ry * (1 - l.feather)).position(c).allowsHitTesting(false)
            handle(at: c, filled: true) { d in moved(l, d, s) { q, dx, dy in q.cx += dx; q.cy += dy } }
            handle(at: CGPoint(x: c.x + rx, y: c.y), filled: false) { d in moved(l, d, s) { q, dx, _ in q.rx = max(q.rx + dx, 0.02) } }
            handle(at: CGPoint(x: c.x, y: c.y + ry), filled: false) { d in moved(l, d, s) { q, _, dy in q.ry = max(q.ry + dy, 0.02) } }
        }
    }

    private func handle(at p: CGPoint, filled: Bool, drag: @escaping (DragGesture.Value?) -> Void) -> some View {
        Circle()
            .fill(filled ? Color.labRed : Color.black.opacity(0.35))
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .frame(width: 22, height: 22)
            .contentShape(Circle().inset(by: -14))
            .position(p)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag($0) }.onEnded { _ in drag(nil) })
    }

    /// A handle dragged: `change` given the layer as the drag began and the move in picture fractions.
    private func moved(_ l: LocalAdjustment, _ d: DragGesture.Value?, _ s: CGSize,
                       _ change: (inout LocalAdjustment, Double, Double) -> Void) {
        guard let d else { start = nil; return }
        let base = start ?? l
        if start == nil { start = l }
        var q = base
        change(&q, Double(d.translation.width / max(s.width, 1)), Double(d.translation.height / max(s.height, 1)))
        model.edit { r in
            var list = r.localAdjustments ?? []
            if let i = list.firstIndex(where: { $0.id == q.id }) { list[i] = q }
            r.localAdjustments = list
        }
    }
}
