//
//  ExportSheet.swift — format, colour space, quality and destination for a
//  full-resolution export, and the share sheet for "文件 / 分享".
//

import SwiftUI
import UIKit

struct ExportSheet: View {
    @ObservedObject var model: ViewModel
    @Environment(\.dismiss) private var dismiss
    /// The print of this photo already in Photos, while the replace / keep-both question is up.
    @State private var previousPrint: (assetID: String, changed: Bool)?

    private func start(replacing: String?) {
        dismiss()
        _ = Task<Void, Never> { @MainActor in
            await model.export(replacing: replacing)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                estimateSection

                Section {
                    ForEach(ExportPreset.all) { preset in
                        Button { preset.apply(to: &model.exportOptions) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title).foregroundStyle(Color.labCream)
                                    Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if preset.matches(model.exportOptions) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.labRed)
                                }
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "推荐设置"))
                } footer: {
                    Text(String(localized: "不确定选什么，用「日常」就好。下面可以再单独调。"))
                }

                Section {
                    Picker(String(localized: "格式"), selection: $model.exportOptions.format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(String(localized: "格式"))
                } footer: {
                    Text(model.exportOptions.format.detail)
                }

                Section {
                    Picker(String(localized: "色彩空间"), selection: $model.exportOptions.colorSpace) {
                        ForEach(ExportColorSpace.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(String(localized: "色彩空间"))
                } footer: {
                    Text(model.exportOptions.colorSpace.detail)
                }

                if model.exportOptions.format.usesQuality {
                    Section {
                        HStack {
                            Slider(value: $model.exportOptions.quality, in: 0.7...1.0, step: 0.01)
                            Text("\(Int((model.exportOptions.quality * 100).rounded()))")
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    } header: {
                        Text(String(localized: "质量"))
                    } footer: {
                        Text(String(localized: "推荐 90：和 100 肉眼看不出差别，文件小一半左右；低于 80 在天空、暗部会出现压缩痕迹。"))
                    }
                }

                Section {
                    Toggle(String(localized: "保留相机 EXIF 与定位"), isOn: $model.exportOptions.keepMetadata)
                    Picker(String(localized: "保存到"), selection: $model.exportOptions.destination) {
                        ForEach(ExportDestination.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text(String(localized: "按原图像素尺寸完整重新渲染。选择「文件 / 分享」可以存到「文件」App、AirDrop 到 Mac，或发给其他 App。"))
                }

                if model.exportOptions.format == .jpeg && model.exportOptions.colorSpace == .proPhoto {
                    Section {
                        Label(String(localized: "ProPhoto 配 8 位 JPEG 容易出现色带，建议改用 TIFF 或 HEIF。"),
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle(String(localized: "导出"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "导出")) {
                        // A print of this photo already in Photos: ask first (replace, keep both, or not now).
                        if model.exportOptions.destination == .photos, let previous = model.previousPrint() {
                            previousPrint = previous
                        } else {
                            start(replacing: nil)
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .confirmationDialog(String(localized: "“照片”里已经有这张的成片"),
                            isPresented: Binding(get: { previousPrint != nil }, set: { if !$0 { previousPrint = nil } }),
                            titleVisibility: .visible, presenting: previousPrint) { previous in
            Button(String(localized: "替换旧的成片")) { start(replacing: previous.assetID) }
            Button(String(localized: "另存一张")) { start(replacing: nil) }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: { previous in
            Text(previous.changed
                 ? String(localized: "上次导出后改过这张照片（胶片、相纸、曝光、后期或裁剪），新成片会和旧的不一样。替换会把旧的移到“最近删除”。")
                 : String(localized: "上次导出后没有改过，新成片和旧的一样。替换会把旧的移到“最近删除”。"))
        }
        .tint(Color.labRed)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.labInk)
        .onAppear { model.refreshExportEstimate() }
        .onChange(of: model.exportOptions) { model.refreshExportEstimate() }
    }

    @ViewBuilder
    private var estimateSection: some View {
        Section {
            if let estimate = model.exportEstimate {
                LabeledContent(String(localized: "尺寸")) {
                    Text("\(estimate.width) × \(estimate.height) · \(String(format: "%.1f", estimate.megapixels)) MP")
                        .monospacedDigit()
                }
                if let original = model.exportCappedFromMegapixels {
                    Text(String(localized: "原图 \(String(format: "%.1f", original)) MP。手机内存放不下全尺寸冲洗，按上面的尺寸导出。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(String(localized: "预计大小")) {
                    if let bytes = estimate.bytes {
                        Text(String(localized: "约 ") + Self.format(bytes: bytes))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(String(localized: "估算中…")).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(String(localized: "打开一张照片后可以看到预计尺寸和大小"))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "预计输出"))
        } footer: {
            if let estimate = model.exportEstimate, estimate.bytes != nil, !estimate.calibrated {
                Text(String(localized: "按预览图推算，偏差可能较大。这个格式导出过一次后，会按实际结果自动校准。"))
            }
        }
    }

    private static func format(bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes >= 10
            ? String(format: "%.0f MB", megabytes)
            : String(format: "%.1f MB", megabytes)
    }
}

/// UIKit's share sheet (Save to Files, AirDrop, other apps), presented from
/// the top-most view controller. Presenting it through a SwiftUI `.sheet`
/// raced the export sheet's dismissal and was silently dropped.
enum ShareController {
    @MainActor
    static func present(url: URL, onFinish: @escaping @MainActor () -> Void) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
                ?? scene?.windows.first?.rootViewController else {
            onFinish()
            return
        }
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            MainActor.assumeIsolated { onFinish() }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80,
                                        width: 1, height: 1)
        }
        top.present(controller, animated: true)
    }
}


/// The export settings alone (presets, format, colour space, quality) for the exports made without the editor:
/// 挑片 and the wall's batch export. The same `exportOptions` the editor's 导出 page sets.
struct ExportSettingsSheet: View {
    @ObservedObject var model: ViewModel
    @Environment(\.dismiss) private var dismiss

    static func summary(_ o: ExportOptions) -> String {
        "\(o.format.title) · \(o.colorSpace.title)" + (o.format.usesQuality ? String(localized: " · 质量 \(Int((o.quality * 100).rounded()))") : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ExportPreset.all) { preset in
                        Button { preset.apply(to: &model.exportOptions) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title).foregroundStyle(Color.labCream)
                                    Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if preset.matches(model.exportOptions) { Image(systemName: "checkmark").foregroundStyle(Color.labRed) }
                            }
                        }
                    }
                } header: { Text(String(localized: "推荐设置")) }
                Section {
                    Picker(String(localized: "格式"), selection: $model.exportOptions.format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text(String(localized: "格式")) } footer: { Text(model.exportOptions.format.detail) }
                Section {
                    Picker(String(localized: "色彩空间"), selection: $model.exportOptions.colorSpace) {
                        ForEach(ExportColorSpace.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text(String(localized: "色彩空间")) } footer: { Text(model.exportOptions.colorSpace.detail) }
                if model.exportOptions.format.usesQuality {
                    Section {
                        HStack {
                            Slider(value: $model.exportOptions.quality, in: 0.7...1.0, step: 0.01)
                            Text("\(Int((model.exportOptions.quality * 100).rounded()))").monospacedDigit().frame(width: 36, alignment: .trailing)
                        }
                    } header: { Text(String(localized: "质量")) } footer: { Text(String(localized: "推荐 90：和 100 肉眼看不出差别，文件小一半左右。")) }
                }
                Section {
                    Toggle(String(localized: "保留相机 EXIF 与定位"), isOn: $model.exportOptions.keepMetadata)
                } footer: {
                    Text(String(localized: "批量导出都存到“照片”，每张按原图全尺寸、用它自己的配方冲洗。这些设置和编辑页“导出”里的是同一套。"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle(String(localized: "导出设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "好")) { dismiss() }.fontWeight(.semibold) } }
        }
        .tint(Color.labRed)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.labInk)
        .preferredColorScheme(.dark)
    }
}
