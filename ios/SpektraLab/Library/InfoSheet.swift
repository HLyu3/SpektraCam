//  InfoSheet.swift — 照片信息, after upstream's Info sheet: what the camera recorded, how it is developed, where the
//  original lives, and its export. Label left, value right, in four groups. The camera's record is read from the
//  original's own metadata (a Photos original is fetched, iCloud allowed), so it shows a moment after the rest.

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct InfoSheet: View {
    @ObservedObject var model: ViewModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var capture: ViewModel.CaptureInfo?
    @State private var reading = true

    var body: some View {
        NavigationStack {
            Form {
                if let p = model.library.first(where: { $0.id == id }) {
                    Section(String(localized: "拍摄")) {
                        if reading {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(String(localized: "正在读取原图…")).foregroundStyle(.secondary) }
                        } else {
                            row(String(localized: "相机"), capture?.camera)
                            row(String(localized: "镜头"), capture?.lens)
                            row(String(localized: "曝光"), capture?.exposure)
                            row(String(localized: "拍摄时间"), (capture?.date ?? p.capturedAt)?.formatted(date: .long, time: .shortened))
                        }
                        row(String(localized: "原图尺寸"), "\(p.pixelWidth) × \(p.pixelHeight) · \(String(format: "%.1f", p.megapixels)) MP")
                        row(String(localized: "格式"), formatText(p))
                    }
                    Section(String(localized: "冲洗")) {
                        let r = p.recipe
                        row(String(localized: "胶片"), model.filmName(for: r.filmID))
                        if r.noFilm != true {
                            row(String(localized: "相纸"), model.catalog.isSlide(r.filmStock) ? String(localized: "扫描（反转片）") : model.filmName(for: r.printStock))
                        }
                        row(String(localized: "改过"), changes(p))
                        if p.pair != nil { row(String(localized: "来自"), String(localized: "两张照片做成的双拼")) }
                    }
                    Section(String(localized: "位置")) {
                        row(String(localized: "原图"), p.assetID != nil ? String(localized: "在“照片”里（Spektra Cam 只存配方和缩略图）")
                                                                     : String(localized: "存在 Spektra Cam 里"))
                        row(String(localized: "文件名"), p.name)
                        if let bytes = capture?.bytes { row(String(localized: "文件大小"), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                        row(String(localized: "加入时间"), p.createdAt.formatted(date: .long, time: .shortened))
                    }
                    Section(String(localized: "导出")) {
                        row(String(localized: "上次导出到相册"), p.exportedAt?.formatted(date: .long, time: .shortened) ?? String(localized: "还没导出过"))
                        if p.exportedAt != nil, let look = p.exportedLook {
                            row(String(localized: "之后改过"), look == model.exportLookKey(recipe: p.recipe, crop: p.crop) ? String(localized: "没有") : String(localized: "改过，成片和现在不一样"))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle(String(localized: "照片信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "好")) { dismiss() }.fontWeight(.semibold) } }
        }
        .tint(Color.labRed)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.labInk)
        .preferredColorScheme(.dark)
        .task {
            capture = await model.captureInfo(for: id)
            reading = false
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? String(localized: "没有记录")).foregroundStyle(value == nil ? .secondary : Color.labCream)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func formatText(_ p: LibraryPhoto) -> String {
        let ext = (p.name as NSString).pathExtension.uppercased()
        let kind = ext.isEmpty ? (p.typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension?.uppercased() } ?? "—") : ext
        return p.isRAW ? "\(kind) · RAW" : kind
    }

    /// What was changed from a fresh develop, as words.
    private func changes(_ p: LibraryPhoto) -> String {
        let r = p.recipe
        var out: [String] = []
        if let c = p.crop, !c.isIdentity { out.append(String(localized: "裁剪")) }
        if (r.sceneBalance != nil) { out.append(String(localized: "白平衡")) }
        if (r.sceneCurve != nil) { out.append(String(localized: "解码曲线")) }
        if (!r.params.isEmpty) || r.exposureMethod != nil { out.append(String(localized: "冲洗参数")) }
        if r.filmBorderEnabled { out.append(String(localized: "片边")) }
        if r.dateBackEnabled { out.append(String(localized: "日期")) }
        if ((r.leakKind ?? "off") != "off") { out.append(String(localized: "漏光")) }
        if (r.diffusionFamily != nil) { out.append(String(localized: "柔焦镜")) }
        if (r.lensCharacter != nil) { out.append(String(localized: "镜头特性")) }
        if r.finishActive { out.append(String(localized: "后期")) }
        if (!(r.localAdjustments ?? []).isEmpty) { out.append(String(localized: "局部调整")) }
        if (!(r.watermarks ?? []).isEmpty) { out.append(String(localized: "水印")) }
        if r.hdr == true { out.append("HDR") }
        return out.isEmpty ? String(localized: "没改过") : out.joined(separator: String(localized: "、"))
    }

}
