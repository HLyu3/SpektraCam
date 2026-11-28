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

                ExportSizeAndNameSections(options: $model.exportOptions, fullSize: model.exportFullOutputSize,
                                          context: model.exportNamingContext() ?? .example)

                Section {
                    Toggle(String(localized: "保留相机 EXIF 与定位"), isOn: $model.exportOptions.keepMetadata)
                    Picker(String(localized: "保存到"), selection: $model.exportOptions.destination) {
                        ForEach(ExportDestination.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text(String(localized: "按上面的尺寸完整重新渲染。选择「文件 / 分享」可以存到「文件」App、AirDrop 到 Mac，或发给其他 App。"))
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
                ExportSizeAndNameSections(options: $model.exportOptions, fullSize: nil, context: .example)
                Section {
                    Toggle(String(localized: "保留相机 EXIF 与定位"), isOn: $model.exportOptions.keepMetadata)
                } footer: {
                    Text(String(localized: "批量导出都存到“照片”，每张用它自己的配方冲洗。这些设置和编辑页“导出”里的是同一套。"))
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

/// 尺寸 and 文件名: the rows both export sheets share (upstream's Size page and naming chips).
struct ExportSizeAndNameSections: View {
    @Binding var options: ExportOptions
    /// What the photo in front comes out as at full size; nil for a batch.
    let fullSize: (width: Int, height: Int)?
    /// What the name is made of: the photo in front's, or an example for a batch.
    let context: ExportNaming.Context

    /// The whole name this photo gets now, extension and all — shown live above the chips.
    private var fileName: String {
        let base = options.naming?.name(context) ?? "SpektraCam_\(ExportNaming.stamp(context.date))"
        return "\(base).\(options.format.fileExtension)"
    }

    var body: some View {
        Section {
            NavigationLink {
                ExportSizePage(size: $options.size, fullSize: fullSize)
            } label: {
                LabeledContent(String(localized: "尺寸"), value: options.size?.title ?? String(localized: "原尺寸"))
            }
        } footer: {
            Text(String(localized: "不会比原图更大。"))
        }
        Section {
            // The name as it is now: every tap below changes it here at once.
            Text(fileName)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.labCream)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.numericText())
                .animation(.snappy, value: fileName)
            Toggle(String(localized: "自定义文件名"), isOn: Binding(get: { options.naming != nil },
                                                                set: { options.naming = $0 ? ExportNaming() : nil }))
            if let naming = options.naming {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(naming.order) { chip($0, naming) } }
                }
                Picker(String(localized: "分隔符"), selection: Binding(get: { naming.separator },
                                                                    set: { options.naming?.separator = $0 })) {
                    ForEach(ExportNaming.separators, id: \.self) { Text($0 == " " ? String(localized: "空格") : $0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text(String(localized: "文件名"))
        } footer: {
            Text(options.naming != nil
                 ? String(localized: "点一下加入或拿掉（亮的会出现在文件名里），长按往前或往后挪。每项下面是它会加进去的内容，写「无」的这张照片没有（比如无胶片的照片没有胶片和相纸）。最上面就是导出后的文件名。")
                 : String(localized: "打开后可以用原文件名、胶片、相纸、日期组合文件名。"))
        }
    }

    private func chip(_ t: ExportNaming.Token, _ naming: ExportNaming) -> some View {
        let on = naming.on.contains(t)
        let value = ExportNaming.part(t, context)
        return Button {
            // The last part on stays on: a name needs one.
            if on { if naming.on.count > 1 { options.naming?.on.remove(t) } } else { options.naming?.on.insert(t) }
        } label: {
            // The part's name over what it puts in the file name — "无" when this photo has nothing for it
            // (无胶片 has no film or paper): lit, it then changes nothing, and says so.
            VStack(spacing: 1) {
                Text(t.title).font(.system(size: 13, weight: on ? .semibold : .medium))
                Text(value.isEmpty ? String(localized: "无") : value)
                    .font(.system(size: 10, weight: .regular)).lineLimit(1)
                    .opacity(value.isEmpty ? 0.5 : 0.75)
                    .frame(maxWidth: 120)
            }
            .foregroundStyle(on ? Color.black : Color.labCream)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(on ? Color.labCream.opacity(value.isEmpty ? 0.45 : 1) : Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: "往前")) { shift(t, -1) }.disabled(naming.order.first == t)
            Button(String(localized: "往后")) { shift(t, 1) }.disabled(naming.order.last == t)
        }
    }

    private func shift(_ t: ExportNaming.Token, _ by: Int) {
        guard var order = options.naming?.order, let i = order.firstIndex(of: t) else { return }
        let j = min(max(i + by, 0), order.count - 1)
        order.swapAt(i, j)
        options.naming?.order = order
    }
}

/// 尺寸: full size, 12 MP, or a long or short edge typed in pixels — each says what it makes of the photo in front.
struct ExportSizePage: View {
    @Binding var size: ExportSize?
    let fullSize: (width: Int, height: Int)?
    @State private var longText = ""
    @State private var shortText = ""
    @FocusState private var typing: Bool?      // true = long edge, false = short

    var body: some View {
        Form {
            Section {
                row(String(localized: "原尺寸"), picked: size == nil, line: line(nil)) { size = nil }
                row("12 MP", picked: size == .twelve, line: line(.twelve)) { size = .twelve }
                edgeRow(long: true)
                edgeRow(long: false)
            } footer: {
                Text(String(localized: "填的数字比原图还大时按原图尺寸。手机内存不够时还会自动缩小。"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.labInk.ignoresSafeArea())
        .navigationTitle(String(localized: "尺寸"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if typing != nil {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { typing = nil } }
            }
        }
        .onAppear {
            if case .longEdge(let e) = size { longText = "\(e)" }
            if case .shortEdge(let e) = size { shortText = "\(e)" }
            if longText.isEmpty { longText = "\(fullSize.map { min(4096, max($0.width, $0.height)) } ?? 4096)" }
            if shortText.isEmpty { shortText = "\(fullSize.map { min(2048, min($0.width, $0.height)) } ?? 2048)" }
        }
    }

    private func row(_ title: String, picked: Bool, line: String?, pick: @escaping () -> Void) -> some View {
        Button(action: pick) { label(title, picked: picked, line: line) }
            .buttonStyle(.plain)
    }

    private func label(_ title: String, picked: Bool, line: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").foregroundStyle(Color.labRed).opacity(picked ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.labCream)
                if let line { Text(line).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func edgeRow(long: Bool) -> some View {
        let value = edgeValue(long)
        let picked = size == value
        return HStack {
            Button { size = value; typing = long } label: {
                label(long ? String(localized: "长边") : String(localized: "短边"), picked: picked, line: line(value))
            }
            .buttonStyle(.plain)
            TextField("", text: long ? $longText : $shortText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($typing, equals: long)
                .frame(width: 80)
                .padding(.horizontal, 8).frame(height: 32)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: long ? longText : shortText) { size = edgeValue(long) }
            Text("px").foregroundStyle(.secondary)
        }
    }

    private func edgeValue(_ long: Bool) -> ExportSize {
        let n = max(Int(long ? longText : shortText) ?? 0, ExportSize.smallestEdge)
        return long ? .longEdge(n) : .shortEdge(n)
    }

    /// "4096 × 2731 · 11.2 MP" for the photo in front.
    private func line(_ s: ExportSize?) -> String? {
        guard let full = fullSize else { return nil }
        let k = s?.scale(width: full.width, height: full.height) ?? 1
        let w = Int((Double(full.width) * k).rounded()), h = Int((Double(full.height) * k).rounded())
        return "\(w) × \(h) · \(String(format: "%.1f", Double(w * h) / 1_000_000)) MP" + (k >= 1 && s != nil ? String(localized: "（原图尺寸）") : "")
    }
}
