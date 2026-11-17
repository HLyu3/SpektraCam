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
                    Picker("格式", selection: $model.exportOptions.format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("格式")
                } footer: {
                    Text(model.exportOptions.format.detail)
                }

                Section {
                    Picker("色彩空间", selection: $model.exportOptions.colorSpace) {
                        ForEach(ExportColorSpace.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("色彩空间")
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
                        Text("质量")
                    }
                }

                Section {
                    Toggle("保留相机 EXIF 与定位", isOn: $model.exportOptions.keepMetadata)
                    Picker("保存到", selection: $model.exportOptions.destination) {
                        ForEach(ExportDestination.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("按原图像素尺寸完整重新渲染。选择「文件 / 分享」可以存到「文件」App、AirDrop 到 Mac，或发给其他 App。")
                }

                if model.exportOptions.format == .jpeg && model.exportOptions.colorSpace == .proPhoto {
                    Section {
                        Label("ProPhoto 配 8 位 JPEG 容易出现色带，建议改用 TIFF 或 HEIF。",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出") {
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
        .confirmationDialog("“照片”里已经有这张的成片",
                            isPresented: Binding(get: { previousPrint != nil }, set: { if !$0 { previousPrint = nil } }),
                            titleVisibility: .visible, presenting: previousPrint) { previous in
            Button("替换旧的成片") { start(replacing: previous.assetID) }
            Button("另存一张") { start(replacing: nil) }
            Button("取消", role: .cancel) {}
        } message: { previous in
            Text(previous.changed
                 ? "上次导出后改过这张照片（胶片、相纸、曝光、后期或裁剪），新成片会和旧的不一样。替换会把旧的移到“最近删除”。"
                 : "上次导出后没有改过，新成片和旧的一样。替换会把旧的移到“最近删除”。")
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
                LabeledContent("尺寸") {
                    Text("\(estimate.width) × \(estimate.height) · \(String(format: "%.1f", estimate.megapixels)) MP")
                        .monospacedDigit()
                }
                if let original = model.exportCappedFromMegapixels {
                    Text("原图 \(String(format: "%.1f", original)) MP。手机内存放不下全尺寸冲洗，按上面的尺寸导出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("预计大小") {
                    if let bytes = estimate.bytes {
                        Text("约 " + Self.format(bytes: bytes))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("估算中…").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("打开一张照片后可以看到预计尺寸和大小")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("预计输出")
        } footer: {
            if let estimate = model.exportEstimate, estimate.bytes != nil, !estimate.calibrated {
                Text("按预览图推算，偏差可能较大。这个格式导出过一次后，会按实际结果自动校准。")
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
