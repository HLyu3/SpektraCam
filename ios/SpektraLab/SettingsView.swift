//  SettingsView.swift — the app's settings: the camera and its roll, feedback, new photos, storage.

import Photos
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("SpektraLab.cameraFormat") private var format = CameraController.Format.proRAW.rawValue
    @AppStorage("SpektraLab.cameraSizeMP") private var sizeMP = 12   // ProRAW 12 MP by default (48 MP files are ~75 MB and slow to develop)
    @AppStorage("SpektraLab.cameraLensLabel") private var lensLabel = "x"
    @AppStorage(ViewModel.reopenKey) private var reopenTo = UserDefaults.standard.bool(forKey: "SpektraLab.openToCamera") ? "camera" : "last"
    @AppStorage("SpektraLab.cameraToPhotos") private var toPhotos = false
    @AppStorage("SpektraLab.haptics") private var haptics = true
    @AppStorage(ViewModel.newPhotoKey) private var newPhotoUsesLast = false
    @AppStorage(ImageDecoder.previewLongEdgeKey) private var previewLongEdge = 1920
    @AppStorage("SpektraLab.lensCorrection") private var lensCorrection = true
    @AppStorage("SpektraLab.librarySource") private var source = "app"
    @AppStorage("SpektraLab.libraryFilter") private var filter = "all"
    @State private var body_ = CameraBody.number
    @State private var nextFrame = CameraBody.nextFrame
    @State private var storage = ""
    @State private var cacheBytes: Int64 = 0
    @AppStorage(DevelopCache.keepDaysKey) private var cacheDays = 14
    @AppStorage(ViewModel.negativeKeepDaysKey) private var keepDays = 7
    @AppStorage(ViewModel.unexportedDeleteDaysKey) private var unexportedDays = 0
    @State private var confirmingCleanup = false
    @State private var cleanable: (count: Int, bytes: Int64) = (0, 0)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        RecipesView(model: model)
                    } label: {
                        Label(String(localized: "配方与胶片"), systemImage: "wand.and.stars")
                    }
                }
                Section {
                    LabeledContent(String(localized: "机身")) {
                        HStack(spacing: 10) {
                            Text(String(localized: "\(body_) 号")).monospacedDigit()
                            Button(String(localized: "换一台")) { CameraBody.changeBody(); body_ = CameraBody.number }
                                .buttonStyle(.bordered)
                        }
                    }
                    LabeledContent(String(localized: "过片")) {
                        HStack(spacing: 10) {
                            Text(String(localized: "下一张第 \(nextFrame) 格")).monospacedDigit()
                            Button(String(localized: "换一格")) { CameraBody.advance(); nextFrame = CameraBody.nextFrame }
                                .buttonStyle(.bordered)
                        }
                    }
                    Picker(String(localized: "拍摄"), selection: Binding(get: { "\(format)-\(sizeMP == 0 ? 48 : sizeMP)" },
                                                        set: { id in
                                                            if let m = CaptureMode.all.first(where: { $0.id == id }) {
                                                                format = m.format.rawValue; sizeMP = m.megapixels
                                                            }
                                                        })) {
                        ForEach(CaptureMode.all) { m in
                            VStack(alignment: .leading) {
                                Text(m.title)
                                Text(m.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(m.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker(String(localized: "镜头显示"), selection: $lensLabel) {
                        Text(String(localized: "倍率")).tag("x")
                        Text(String(localized: "焦段")).tag("mm")
                    }
                    Picker(String(localized: "重新打开时"), selection: $reopenTo) {
                        Text(String(localized: "回到上次的位置")).tag("last")
                        Text(String(localized: "回到照片库")).tag("library")
                        Text(String(localized: "总是打开相机")).tag("camera")
                    }
                    Toggle(String(localized: "拍摄的照片也存入“照片”"), isOn: $toPhotos)
                    Picker(String(localized: "底片保留"), selection: $keepDays) {
                        ForEach([1, 3, 7, 14, 30, 60, 90], id: \.self) { Text(String(localized: "\($0) 天")).tag($0) }
                        Text(String(localized: "一直保留")).tag(0)
                    }
                    Picker(String(localized: "未导出的照片"), selection: $unexportedDays) {
                        Text(String(localized: "一直保留")).tag(0)
                        ForEach([7, 14, 30, 60, 90, 180, 365], id: \.self) { Text(String(localized: "\($0) 天后删除")).tag($0) }
                    }
                } header: {
                    Text(String(localized: "相机"))
                } footer: {
                    Text(String(localized: "拍完自动冲洗：每张按装好的胶卷或配方在后台全尺寸冲洗，成片存进“照片”（格式按导出设置）；“无胶卷”不冲洗。\n底片：用 Spektra Cam 相机拍的原片。导出到“照片”以后，过了保留期会自动删除，成片留在“照片”里。没导出过的照片默认一直保留，拍了 3 天以上会在照片库提醒你挑片；选了“N 天后删除”才会自动删，删除前一天照片库会提醒。\n机身号决定片边上和相机有关的细节；每张新照片按顺序占一格，片边印的就是这一格的帧号（1–36 循环）。“拍摄”里的尺寸，换到没有这个尺寸的镜头（如长焦）时用那颗镜头最大的尺寸；48 MP 照片可以全尺寸导出。\n“重新打开时”在启动 App，或离开超过 2 分钟再回来时生效；正在编辑的照片会先保存。"))
                }

                Section(String(localized: "反馈")) {
                    Toggle(String(localized: "触感反馈"), isOn: $haptics)
                }

                Section {
                    Picker(String(localized: "新照片"), selection: $newPhotoUsesLast) {
                        Text(String(localized: "标准配方")).tag(false)
                        Text(String(localized: "上次使用")).tag(true)
                    }
                    Picker(String(localized: "预览尺寸"), selection: $previewLongEdge) {
                        ForEach(ImageDecoder.previewLongEdgeChoices, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Toggle(String(localized: "镜头校正"), isOn: $lensCorrection)
                } header: {
                    Text(String(localized: "冲洗"))
                } footer: {
                    Text(String(localized: "“上次使用”：新导入或新拍的照片，套用最近一次在编辑页调好的配方（拍摄时胶片仍按装好的胶卷）。\n相纸：选胶片时（拍照和编辑都一样）用这卷胶片的推荐相纸，没有推荐的用 Crystal Archive；黑白胶片用自己的黑白相纸。拍照页胶卷名下面的“相纸”按钮里选了推荐相纸中的另一张，以后这卷胶片就用它；选推荐以外的相纸只在这次拍摄有效，想固定请存成配方；编辑时换的相纸只影响那一张。\n预览尺寸：编辑时画面的长边；越大越清楚，拖动时越慢，下次打开照片时生效。导出始终是全尺寸。\n镜头校正：只对 RAW，按照片里记录的相机数据校正畸变和暗角；ProRAW 和大多数 DNG 都带这份数据。"))
                }

                Section {
                    Picker(String(localized: "来源"), selection: $source) {
                        Text(String(localized: "Spektra Cam 图库")).tag("app")
                        Text(String(localized: "系统相册")).tag("photos")
                    }
                    .onChange(of: source) { _, new in filter = new == "photos" ? "photos" : "all" }
                    PhotoAccessRow()
                    LabeledContent(String(localized: "储存空间"), value: storage)
                    // 冲洗缓存: what makes viewing and editing fast; it can always be made again.
                    LabeledContent(String(localized: "冲洗缓存"), value: String(format: "%.0f MB", Double(cacheBytes) / 1_048_576))
                    Picker(String(localized: "缓存保留"), selection: $cacheDays) {
                        ForEach([3, 7, 14, 30, 90], id: \.self) { Text(String(localized: "\($0) 天没看就删")).tag($0) }
                        Text(String(localized: "一直保留")).tag(0)
                    }
                    Button(String(localized: "清除冲洗缓存")) {
                        DevelopCache.prune(in: model.libraryRootURL, olderThanDays: nil)
                        refreshStorage()
                    }
                    .disabled(cacheBytes == 0)
                    Button(cleanable.count == 0 ? String(localized: "没有可清理的底片")
                           : String(format: String(localized: "清理已导出的底片 · %d 张 · %.0f MB"), cleanable.count, Double(cleanable.bytes) / 1_048_576)) {
                        confirmingCleanup = true
                    }
                    .disabled(cleanable.count == 0)
                    .confirmationDialog(String(localized: "删除 \(cleanable.count) 张底片？"), isPresented: $confirmingCleanup, titleVisibility: .visible) {
                        Button(String(localized: "删除底片"), role: .destructive) {
                            model.deletePhotos(Set(model.expendableNegatives(olderThanDays: nil).map(\.id)))
                            refreshStorage()
                        }
                    } message: {
                        Text(String(localized: "这些是用 Spektra Cam 相机拍的原片，成片已经导出到“照片”。删除后不能再重新冲洗，成片不受影响。"))
                    }
                } header: {
                    Text(String(localized: "照片库"))
                } footer: {
                    Text(String(localized: "从相册添加照片时，只关联不复制，原图留在相册里。\n相册权限选了“部分照片”时，只能冲洗你选过的那些；改成“完全访问”要到系统设置 › Spektra Cam › 照片。\n“系统相册”：照片库里多一个“系统相册”视图，直接冲洗相册里的照片——原图留在相册里不动，Spektra Cam 只记下配方和冲洗后的缩略图；RAW + JPEG 的照片按 RAW 冲洗。\n冲洗缓存：每张冲过的照片会留一份清晰版和编辑用的画面（每张约 30–50 MB），让查看和编辑能马上打开；超过设定天数没看过的会自动删除，需要时会重新冲洗，删掉不会丢照片。"))
                }

                Section(String(localized: "关于")) {
                    LabeledContent("Spektra Cam",
                                   value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Text(String(localized: "基于 SpektraLab 引擎（JamesQiu2005/SpektraLab）与它的 iOS 社区移植版（Minerchu/SpektraLab-iOS），GPL-3。胶片和相纸特性文件来自 Andrea Volpato 的 spektrafilm（CC BY-SA 4.0）。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle(String(localized: "设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { dismiss() }.fontWeight(.semibold) }
            }
            .task { refreshStorage() }
        }
        .tint(Color.labRed)
        .preferredColorScheme(.dark)
        .presentationBackground(Color.labInk)
    }

    private func refreshStorage() {
        let bytes = model.libraryBytes()
        cacheBytes = DevelopCache.bytes(in: model.libraryRootURL)
        storage = String(format: String(localized: "%.1f GB · %d 张"), Double(bytes) / 1_073_741_824, model.library.count)
        let negatives = model.expendableNegatives(olderThanDays: nil)
        cleanable = (negatives.count, model.negativeBytes(negatives))
    }
}

/// 相册权限: what the app may read, and where to change it. Limited access ("选择照片") can add photos with the
/// system picker; anything else is changed in iOS Settings, which this opens (the app cannot ask twice).
struct PhotoAccessRow: View {
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.scenePhase) private var phase

    private var label: String {
        switch status {
        case .authorized: String(localized: "完全访问")
        case .limited: String(localized: "部分照片")
        case .denied, .restricted: String(localized: "不允许")
        default: String(localized: "未设置")
        }
    }

    var body: some View {
        LabeledContent(String(localized: "相册权限"), value: label)
            // Back from Settings: read it again.
            .onChange(of: phase) { _, p in
                if p == .active { status = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            }
        if status == .limited {
            Button(String(localized: "选择更多可访问的照片…")) {
                guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                    .first?.rootViewController else { return }
                var top = root
                while let next = top.presentedViewController { top = next }
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
            }
        }
        if status == .notDetermined {
            Button(String(localized: "允许访问相册")) {
                Task { @MainActor in status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            }
        } else if status != .authorized {
            Button(String(localized: "到系统设置改为“完全访问”")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }
}
