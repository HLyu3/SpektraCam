//  Watermark.swift — 水印: marks (PNG logos, or a line of text made into one) laid over the finished picture.
//  Trimmed from upstream's `Model/Watermark.swift` (2.4.1): the same placement — measured from the nearest corner
//  in fractions of the picture's SHORT side, so a corner logo sits the same on a portrait and a landscape frame —
//  and the same drawing order (first = bottom). Not ported: the 底片 stage (a mark the film develops), canvas
//  gestures (here: corner, margin, size, turn and opacity controls), guides and snapping.
//
//  The marks live in `<library>/watermarks/<uuid>.png`; a photo's placements are in its recipe (so paste and saved
//  recipes carry them) and never reach the engine.

import CoreGraphics
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct WatermarkPlacement: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id = UUID()
    /// The mark's file (`WatermarkShelf`); one since deleted draws nothing.
    var mark: UUID
    /// The corner `dx`, `dy` are measured from: "br" · "bl" · "tr" · "tl" (`DateBackCorner`).
    var anchor = "br"
    /// The mark's centre in from `anchor`, and its width — fractions of the picture's short side.
    var dx = 0.2
    var dy = 0.1
    var size = 0.3
    /// Degrees, clockwise.
    var rotation = 0.0
    var opacity = 1.0
    /// nil = the PNG's own colours; "white" / "black" fills the mark's shape.
    var fill: String? = nil

    var corner: DateBackCorner { DateBackCorner(rawValue: anchor) ?? .br }
    var isRight: Bool { corner == .br || corner == .tr }
    var isBottom: Bool { corner == .br || corner == .bl }

    /// The gap between the mark's edges and the picture's (short-side fractions), for a mark of `aspect` (w ÷ h).
    func margin(aspect: Double) -> Double { max(0, dx - size / 2) }

    /// Re-measured so its outer edges sit `margin` in from `anchor`'s two edges.
    func placed(margin: Double, aspect: Double) -> WatermarkPlacement {
        var p = self
        p.dx = margin + size / 2
        p.dy = margin + size / max(aspect, 0.01) / 2
        return p
    }

    /// Where it is drawn on a canvas of `canvas` (any unit, y down): centre, size before the turn.
    func frame(canvas: CGSize, aspect: Double) -> (center: CGPoint, size: CGSize) {
        let s = Double(min(canvas.width, canvas.height))
        let w = size * s, h = w / max(aspect, 0.01)
        let x = isRight ? Double(canvas.width) - dx * s : dx * s
        let y = isBottom ? Double(canvas.height) - dy * s : dy * s
        return (CGPoint(x: x, y: y), CGSize(width: w, height: h))
    }
}

enum Watermark {
    static let maxPerPhoto = 4

    /// `image` with the marks drawn over it, at its own bit depth and colour space. Off the main actor.
    nonisolated static func composite(_ image: CGImage, _ marks: [(WatermarkPlacement, CGImage)]) -> CGImage {
        guard !marks.isEmpty else { return image }
        let w = image.width, h = image.height
        let deep = image.bitsPerComponent > 8
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: deep ? 16 : 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // y down, as the placement measures.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        for (p, mark) in marks {
            let aspect = Double(mark.width) / Double(max(mark.height, 1))
            let f = p.frame(canvas: CGSize(width: w, height: h), aspect: aspect)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(min(max(p.opacity, 0), 1)))
            ctx.translateBy(x: f.center.x, y: f.center.y)
            ctx.rotate(by: CGFloat(p.rotation * .pi / 180))
            // The mark upright in y-down space: flip it back inside its own box.
            ctx.scaleBy(x: 1, y: -1)
            let box = CGRect(x: -f.size.width / 2, y: -f.size.height / 2, width: f.size.width, height: f.size.height)
            if let fill = p.fill {
                ctx.clip(to: box, mask: mark)
                ctx.setFillColor(fill == "black" ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
                ctx.fill(box)
            } else {
                ctx.draw(mark, in: box)
            }
            ctx.restoreGState()
        }
        return ctx.makeImage() ?? image
    }

    /// A line of text as a white PNG on clear (the mark a phone user can make without a logo file).
    static func textMark(_ text: String) -> Data? {
        let font = UIFont.systemFont(ofSize: 160, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        guard size.width > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(size.width) + 20, height: ceil(size.height) + 20), format: format)
            .image { _ in (text as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: attrs) }
        return image.pngData()
    }
}

/// The marks on disk, and their pictures cached.
@MainActor
final class WatermarkShelf: ObservableObject {
    @Published private(set) var marks: [UUID] = []
    private var cache: [UUID: CGImage] = [:]
    private let folder: URL

    init(root: URL) {
        folder = root.appendingPathComponent("watermarks", isDirectory: true)
        reload()
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".png") }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        marks = files.filter { $0.pathExtension == "png" }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }

    /// Any picture ImageIO reads, kept as PNG (its transparency with it), at most 2048 px.
    @discardableResult
    func add(_ data: Data) -> UUID? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        guard let dest = CGImageDestinationCreateWithURL(url(id) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        cache[id] = image
        reload()
        return id
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        cache[id] = nil
        reload()
    }

    func image(_ id: UUID) -> CGImage? {
        if let c = cache[id] { return c }
        guard let src = CGImageSourceCreateWithURL(url(id) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cache[id] = image
        return image
    }

    func aspect(_ id: UUID) -> Double {
        guard let i = image(id) else { return 1 }
        return Double(i.width) / Double(max(i.height, 1))
    }

    /// A recipe's placements with their pictures, ready for `Watermark.composite`.
    func resolved(_ placements: [WatermarkPlacement]?) -> [(WatermarkPlacement, CGImage)] {
        (placements ?? []).compactMap { p in image(p.mark).map { (p, $0) } }
    }
}

// MARK: - the preview overlay

/// The marks over the canvas's picture (aspect-fit in `area`), as the export will draw them.
struct WatermarkOverlay: View {
    let placements: [WatermarkPlacement]
    let shelf: WatermarkShelf
    let picture: CGSize
    let area: CGSize

    var body: some View {
        let k = min(area.width / max(picture.width, 1), area.height / max(picture.height, 1))
        let shown = CGSize(width: picture.width * k, height: picture.height * k)
        ZStack(alignment: .topLeading) {
            ForEach(placements) { p in
                if let mark = shelf.image(p.mark) {
                    let f = p.frame(canvas: shown, aspect: Double(mark.width) / Double(max(mark.height, 1)))
                    Group {
                        if let fill = p.fill {
                            Rectangle().fill(fill == "black" ? Color.black : Color.white)
                                .mask(Image(decorative: mark, scale: 1).resizable())
                        } else {
                            Image(decorative: mark, scale: 1).resizable()
                        }
                    }
                    .frame(width: f.size.width, height: f.size.height)
                    .rotationEffect(.degrees(p.rotation))
                    .opacity(p.opacity)
                    .position(f.center)
                }
            }
        }
        .frame(width: shown.width, height: shown.height)
        .frame(width: area.width, height: area.height)
        .allowsHitTesting(false)
    }
}

// MARK: - the 水印 panel

struct WatermarkPanel: View {
    @ObservedObject var model: ViewModel
    @ObservedObject var shelf: WatermarkShelf
    @State private var chosen: UUID?
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pickingFile = false
    @State private var writing = false
    @State private var text = ""
    @State private var removing: UUID?

    private var placements: [WatermarkPlacement] { model.recipe.watermarks ?? [] }
    private var current: WatermarkPlacement? { placements.first { $0.id == chosen } ?? placements.last }

    var body: some View {
        ToolScroll {
            Text("水印库 · 点一下放到照片上，长按删除").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Button { pickingPhoto = true } label: { Label("从相册（PNG 透明底最好）", systemImage: "photo") }
                        Button { pickingFile = true } label: { Label("从文件", systemImage: "folder") }
                        Button { text = ""; writing = true } label: { Label("用文字做一个", systemImage: "textformat") }
                    } label: {
                        Image(systemName: "plus").font(.title3)
                            .frame(width: 56, height: 56)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(shelf.marks, id: \.self) { id in
                        markTile(id)
                    }
                }
            }
            if let p = current {
                if placements.count > 1 {
                    Picker("水印", selection: Binding(get: { p.id }, set: { chosen = $0 })) {
                        ForEach(Array(placements.enumerated()), id: \.element.id) { i, q in Text("水印 \(i + 1)").tag(q.id) }
                    }
                    .pickerStyle(.segmented)
                }
                controls(p)
            } else {
                Note("还没有水印。点 ＋ 添加一个 PNG（透明底的签名或标志最好），或用文字做一个。导出的成片、缩略图和观片台都会带上。")
            }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self), let id = shelf.add(data) { place(id) }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.png, .image]) { result in
            guard let url = try? result.get() else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let id = shelf.add(data) { place(id) }
        }
        .alert("文字水印", isPresented: $writing) {
            TextField("例如 © 你的名字", text: $text)
            Button("取消", role: .cancel) {}
            Button("做好") { if let data = Watermark.textMark(text), let id = shelf.add(data) { place(id) } }
        }
        .confirmationDialog("从水印库删除这个水印？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let id = removing { shelf.delete(id) }; removing = nil }
        } message: { Text("已经放上去的照片不再显示它。") }
    }

    private func markTile(_ id: UUID) -> some View {
        Button { place(id) } label: {
            Group {
                if let image = shelf.image(id) { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(6) }
                else { Color.clear }
            }
            .frame(width: 56, height: 56)
            .background(Color(white: 0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu { Button(role: .destructive) { removing = id } label: { Label("从水印库删除", systemImage: "trash") } }
    }

    private func place(_ id: UUID) {
        guard placements.count < Watermark.maxPerPhoto else { model.libraryMessage = "一张照片最多 \(Watermark.maxPerPhoto) 个水印"; return }
        let p = WatermarkPlacement(mark: id, size: 0.25).placed(margin: 0.04, aspect: shelf.aspect(id))
        model.edit { r in r.watermarks = (r.watermarks ?? []) + [p] }
        chosen = p.id
    }

    private func update(_ p: WatermarkPlacement) {
        model.edit { r in
            var list = r.watermarks ?? []
            if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p }
            r.watermarks = list
        }
    }

    @ViewBuilder private func controls(_ p: WatermarkPlacement) -> some View {
        let aspect = shelf.aspect(p.mark)
        let margin = p.margin(aspect: aspect)
        ChipRow(title: "位置", options: [("tl", "左上"), ("tr", "右上"), ("bl", "左下"), ("br", "右下")],
                selected: p.anchor) { a in var q = p; q.anchor = a; update(q.placed(margin: margin, aspect: aspect)) }
        FinishSlider(title: "大小", value: Binding(get: { p.size }, set: { v in var q = p; q.size = v; update(q.placed(margin: margin, aspect: aspect)) }),
                     range: 0.03...1, rest: 0.25, text: { String(format: "%.0f%%", $0 * 100) })
        FinishSlider(title: "边距", value: Binding(get: { margin }, set: { update(p.placed(margin: $0, aspect: aspect)) }),
                     range: 0...0.3, rest: 0.04, text: { String(format: "%.0f%%", $0 * 100) })
        FinishSlider(title: "透明度", value: Binding(get: { p.opacity }, set: { v in var q = p; q.opacity = v; update(q) }),
                     range: 0.05...1, rest: 1, text: { String(format: "%.0f%%", $0 * 100) })
        FinishSlider(title: "旋转", value: Binding(get: { p.rotation }, set: { v in var q = p; q.rotation = v.rounded(); update(q) }),
                     range: -180...180, rest: 0, text: { String(format: "%.0f°", $0) })
        ChipRow(title: "颜色", options: [("", "原样"), ("white", "白色"), ("black", "黑色")], selected: p.fill ?? "") { f in
            var q = p; q.fill = f.isEmpty ? nil : f; update(q)
        }
        Button(role: .destructive) {
            model.edit { r in r.watermarks = (r.watermarks ?? []).filter { $0.id != p.id } }
            chosen = nil
        } label: { Label("从这张照片拿掉", systemImage: "minus.circle").font(.footnote) }
    }
}
