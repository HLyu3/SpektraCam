//  EditorDeck.swift — the editor's bottom deck: the darkroom's stages, each a row of tools, and
//  one place where the chosen tool's controls appear.
//
//  To add a feature: give `PhotoRecipe` its field and wire (Model/PhotoLibrary.swift), then add
//  one `EditTool` to `EditTool.all` below — its stage, whether it has moved, how it resets, and
//  its panel. The deck draws the tool row, the modified dots and the reset button from that.

import SwiftUI

/// The darkroom, in the order the light goes: framed, through the lens, exposed onto the film,
/// the film developed, printed onto paper, then finished. Tools inside a stage keep that order too.
enum EditStage: String, CaseIterable, Identifiable {
    case frame = "取景", lens = "镜头", develop = "曝光", film = "胶片", paper = "相纸", finish = "后期"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .frame: "crop"
        case .lens: "camera.aperture"
        case .develop: "sun.max"
        case .film: "film"
        case .paper: "doc.richtext"
        case .finish: "slider.horizontal.3"
        }
    }
}

/// What a panel can ask of the page around it.
struct EditContext {
    let openCrop: () -> Void
    let browseStocks: (_ papers: Bool) -> Void
}

/// One tool: where it lives, whether it has moved from its rest, how it goes back, and its controls.
struct EditTool: Identifiable {
    let id: String
    let title: String
    let stage: EditStage
    var modified: @MainActor (ViewModel) -> Bool = { _ in false }
    var reset: (@MainActor (ViewModel) -> Void)?
    let panel: @MainActor (ViewModel, EditContext) -> AnyView
}

// MARK: - the tools

extension EditTool {
    @MainActor static func tools(in stage: EditStage) -> [EditTool] { all.filter { $0.stage == stage } }

    /// Under 无胶片 the picture is the original as the system renders it: nothing of the lens, exposure, film or
    /// paper reaches it — only the crop, the film picker (to choose one) and the finish (bar HDR, which needs a film).
    static let noFilmTools: Set<String> = ["crop", "film", "light", "colour", "hsl", "curve", "balance", "local", "mixer", "watermark"]

    @MainActor static func tools(in stage: EditStage, noFilm: Bool) -> [EditTool] {
        tools(in: stage).filter { !noFilm || noFilmTools.contains($0.id) }
    }

    /// Sliders for these keys of `ParamCatalog`, as a tool's rows.
    @MainActor static func sliders(_ keys: [FilmParam], _ m: ViewModel) -> some View {
        ForEach(keys.compactMap { ParamCatalog.control(for: $0.key) }) { c in ParamRow(model: m, control: c) }
    }

    @MainActor static func paramsMoved(_ keys: [FilmParam], _ m: ViewModel) -> Bool {
        keys.contains { k in
            guard let c = ParamCatalog.control(for: k.key) else { return false }
            return abs((m.params[k.key] ?? c.defaultValue) - c.defaultValue) > 1e-9
        }
    }

    @MainActor static func resetParams(_ keys: [FilmParam], _ m: ViewModel, also: @escaping (inout PhotoRecipe) -> Void = { _ in }) {
        m.edit { r in
            for k in keys { if let c = ParamCatalog.control(for: k.key) { r.params[k.key] = c.defaultValue } }
            also(&r)
        }
    }

    @MainActor static let all: [EditTool] = [
        // 取景
        EditTool(id: "crop", title: String(localized: "裁剪"), stage: .frame,
                 modified: { !$0.crop.isIdentity },
                 reset: { $0.setCrop(FrameCrop()) },
                 panel: { m, ctx in AnyView(ToolScroll {
                     Button(action: ctx.openCrop) {
                         Label(String(localized: "裁剪、拉直和旋转…"), systemImage: "crop.rotate")
                             .font(.subheadline.weight(.semibold))
                             .frame(maxWidth: .infinity, minHeight: 44)
                             .background(Color.white.opacity(0.08), in: Capsule())
                     }
                     .buttonStyle(.plain)
                     .foregroundStyle(Color.labCream)
                     Note(m.crop.isIdentity ? String(localized: "完整画面。")
                          : String(format: String(localized: "已裁剪 · 拉直 %.1f°"), m.crop.angle) + (m.crop.isOriented ? String(localized: " · 已旋转") : ""))
                 }) }),
        EditTool(id: "format", title: String(localized: "画幅"), stage: .frame,
                 modified: { $0.filmFormatMM != 36 },
                 reset: { $0.setFilmFormat(36) },
                 panel: { m, _ in AnyView(ToolScroll {
                     ChipRow(title: String(localized: "画幅"), options: [("24", String(localized: "半格")), ("36", "135"), ("56", "6×4.5"), ("57", "6×6"), ("70", "6×7"),
                                                     ("84", "6×9"), ("127", "4×5")],
                             selected: String(Int(m.filmFormatMM))) { m.setFilmFormat(Double($0) ?? 36) }
                         .disabled(m.filmBorderEnabled)
                         .opacity(m.filmBorderEnabled ? 0.4 : 1)
                     Note(m.filmBorderEnabled ? String(localized: "开着片边时，画幅跟片边的片幅走。") : String(localized: "底片越大，颗粒和光晕相对画面越细。"))
                 }) }),

        // 镜头
        EditTool(id: "character", title: String(localized: "镜头风格"), stage: .lens,
                 modified: { !$0.lensCharacter.isEmpty },
                 reset: { m in m.edit { $0.lensCharacter = nil; $0.lensAmount = nil } },
                 panel: { m, _ in AnyView(ToolScroll {
                     ChipRow(title: String(localized: "镜头"), options: [("", String(localized: "原装"))] + LensCharacter.allCases.map { ($0.rawValue, $0.title) },
                             selected: m.lensCharacter) { m.setLens(character: $0) }
                     if !m.lensCharacter.isEmpty {
                         FinishSlider(title: String(localized: "程度"), value: Binding(get: { m.lensAmount * 100 }, set: { m.setLens(amount: $0 / 100) }),
                                      range: 0...300, rest: 100, text: { String(format: "%.0f%%", $0) })
                     }
                     Note(String(localized: "效果在画面四周、中间保持清晰。预览尺寸小，100% 时边角只模糊两三个像素；放大边角或导出后看更清楚。"))
                 }) }),
        EditTool(id: "diffusion", title: String(localized: "柔光镜"), stage: .lens,
                 modified: { !$0.diffusionFamily.isEmpty },
                 reset: { m in m.edit { $0.diffusionFamily = nil; $0.diffusionStrength = nil } },
                 panel: { m, _ in AnyView(ToolScroll {
                     ChipRow(title: String(localized: "滤镜"), options: [("", String(localized: "无")), ("black_pro_mist", String(localized: "黑柔")), ("pro_mist", String(localized: "白柔")),
                                                     ("glimmerglass", String(localized: "微光")), ("cinebloom", String(localized: "柔光"))],
                             selected: m.diffusionFamily) { m.setDiffusion(family: $0) }
                     if !m.diffusionFamily.isEmpty {
                         ChipRow(title: String(localized: "强度"), options: [("0.125", "1/8"), ("0.25", "1/4"), ("0.5", "1/2"), ("1.0", "1"), ("2.0", "2")],
                                 selected: String(m.diffusionStrength)) { m.setDiffusion(strength: Double($0)) }
                     }
                     Note(String(localized: "镜头前的柔光滤镜：亮部周围泛起柔光，黑柔更含蓄，白柔更雾。"))
                 }) }),
        EditTool(id: "filter", title: String(localized: "滤镜"), stage: .lens,
                 modified: { !$0.lensFilter.isEmpty },
                 reset: { $0.setLensFilter("") },
                 panel: { m, _ in AnyView(ToolScroll {
                     ChipRow(title: String(localized: "滤镜"), options: [("", String(localized: "无")), ("w8", String(localized: "黄")), ("w21", String(localized: "橙")), ("w25", String(localized: "红")), ("w58", String(localized: "绿")), ("w47", String(localized: "蓝"))],
                             selected: m.lensFilter) { m.setLensFilter($0) }
                     Note(m.catalog.isMonochrome(m.filmStock)
                          ? String(localized: "黑白摄影的经典滤镜：黄、橙、红让天空更暗、云更突出，绿让肤色和树叶更有层次。")
                          : String(localized: "彩色胶片上会给整个画面偏色。黑白胶片上才是常用的反差滤镜。"))
                 }) }),

        // 曝光
        EditTool(id: "exposure", title: String(localized: "曝光"), stage: .develop,
                 // Either default meter is "unmodified": balanced (older photos) or 保高光 (new ones); reset goes to 保高光.
                 modified: { paramsMoved([.exposureCompensation], $0)
                     || !["balanced", "protect_highlights", PhotoRecipe.newPhotoMeter].contains($0.exposureMethod) },
                 // Reset: a camera shot back to 相机, anything imported back to the engine's meter.
                 reset: { m in resetParams([.exposureCompensation], m) {
                     $0.exposureMethod = m.editingPhoto?.captured == true ? PhotoRecipe.shotMeter : nil } },
                 panel: { m, _ in AnyView(ToolScroll {
                     ChipRow(title: String(localized: "测光"), options: [("camera", String(localized: "相机")), ("balanced", String(localized: "均衡")), ("center", String(localized: "中央")), ("protect_highlights", String(localized: "保高光")),
                                                     ("protect_shadows", String(localized: "保阴影")), ("manual", String(localized: "手动"))],
                             selected: m.exposureMethod) { m.setExposureMethod($0) }
                     sliders([.exposureCompensation], m)
                 }) }),
        EditTool(id: "whitebalance", title: String(localized: "白平衡"), stage: .develop,
                 modified: { $0.recipe.sceneBalance != nil },
                 reset: { m in m.edit { $0.sceneBalance = nil }; m.neutralNote = nil },
                 panel: { m, _ in AnyView(ToolScroll {
                     Button { m.neutralNote = m.neutralRefusal; if m.neutralRefusal == nil { m.pickingNeutral.toggle() } } label: {
                         Label(m.pickingNeutral ? String(localized: "点画面里应该是灰色或白色的地方…") : String(localized: "吸管：点一块灰色或白色"),
                               systemImage: "eyedropper")
                             .font(.subheadline.weight(.semibold))
                             .frame(maxWidth: .infinity, minHeight: 44)
                             .background(m.pickingNeutral ? Color.labRed.opacity(0.35) : Color.white.opacity(0.08), in: Capsule())
                     }
                     .buttonStyle(.plain)
                     .foregroundStyle(Color.labCream)
                     Note(m.neutralNote ?? (m.recipe.sceneBalance.map { String(localized: "当前：") + SceneBalance.describe($0) }
                          ?? String(localized: "在胶片曝光之前校正白平衡，像冲洗前给底片加色温滤镜。点白墙、灰卡、白纸这类本该无色的地方；可以多点几次叠加。")))
                 }) }),
        EditTool(id: "decode", title: String(localized: "解码曲线"), stage: .develop,
                 modified: { !$0.sceneCurve.isIdentity },
                 reset: { $0.setSceneCurve(CurveSet()) },
                 panel: { m, _ in AnyView(DecodeCurvePanel(model: m)) }),
        EditTool(id: "placement", title: String(localized: "置位"), stage: .develop,
                 modified: { paramsMoved([.sceneLatitudeActive, .highlightRoom, .shadowRoom], $0) || $0.recipe.autoPlacement == true },
                 reset: { resetParams([.sceneLatitudeActive, .highlightRoom, .shadowRoom], $0) { $0.autoPlacement = nil } },
                 panel: { m, _ in AnyView(ToolScroll {
                     // 自动置位, off by default as on the Mac: the engine fits this photo's scene into the film's latitude.
                     Toggle(String(localized: "自动置位"), isOn: Binding(get: { m.recipe.autoPlacement == true },
                                                  set: { on in m.edit { $0.autoPlacement = on ? true : nil } }))
                         .font(.footnote)
                         .tint(Color.labRed)
                         .disabled((m.params[FilmParam.sceneLatitudeActive.key] ?? 0) >= 0.5)
                     Note(String(localized: "默认关闭，和 Mac 版一样。打开后，自动把太亮的天空和窗外收进胶片能记录的范围，主体亮度基本不变。下面的「场景置位」打开后改为手动。"))
                     sliders([.sceneLatitudeActive], m)
                     if (m.params[FilmParam.sceneLatitudeActive.key] ?? 0) >= 0.5 { sliders([.highlightRoom, .shadowRoom], m) }
                 }) }),

        // 胶片
        EditTool(id: "film", title: String(localized: "胶片"), stage: .film,
                 panel: { m, ctx in AnyView(StockPanel(model: m, papers: false, browse: { ctx.browseStocks(false) })) }),
        EditTool(id: "leak", title: String(localized: "漏光"), stage: .film,
                 modified: { !$0.leakKind.isEmpty || ($0.recipe.leakEdge ?? 0) > 0 || $0.recipe.leakSeed != nil },
                 reset: { m in m.edit { $0.leakKind = nil; $0.leakAmount = nil; $0.leakEdge = nil; $0.leakSeed = nil } },
                 panel: { m, _ in AnyView(ToolScroll {
                     // Engine 2.4.1: a spot on any format (it needed a 120 back's window before).
                     ChipRow(title: String(localized: "漏光"), options: [("", String(localized: "关")), ("auto", String(localized: "自动")), ("band", String(localized: "条带")), ("wash", String(localized: "泛光")), ("spot", String(localized: "光斑"))],
                             selected: m.leakKind) { m.setLeak(kind: $0) }
                     if !m.leakKind.isEmpty {
                         FinishSlider(title: String(localized: "强度"), value: Binding(get: { m.leakAmount }, set: { m.setLeak(amount: $0) }),
                                      range: 0...4, rest: 1, text: { String(format: "%.1f", $0) })
                     }
                     // 边缘烧灼: beside any kind, at its own strength; 0 is off.
                     FinishSlider(title: String(localized: "边缘烧灼"), value: Binding(get: { m.recipe.leakEdge ?? 0 }, set: { m.setLeak(edge: $0) }),
                                  range: 0...4, rest: 0, text: { $0 <= 0 ? String(localized: "关") : String(format: "%.1f", $0) })
                     if !m.leakKind.isEmpty || (m.recipe.leakEdge ?? 0) > 0 {
                         HStack(spacing: 8) {
                             Button { m.shuffleLeak() } label: {
                                 Label(String(localized: "随机位置"), systemImage: "dice").font(.footnote.weight(.semibold))
                             }
                             if m.recipe.leakSeed != nil {
                                 Button { m.shuffleLeak(false) } label: {
                                     Text(String(localized: "回到机身位置")).font(.footnote.weight(.semibold))
                                 }
                             }
                         }
                         .buttonStyle(.bordered)
                         .tint(Color.labCream)
                     }
                     Note(String(localized: "没经过镜头的光漏到胶片上。边缘烧灼是胶片边缘被光烧到的一条亮边，可以单独用，也可以和上面的漏光一起用。位置和形状默认由设置里的机身号决定，“随机位置”给这张照片换一个。"))
                 }) }),
        EditTool(id: "halation", title: String(localized: "光晕"), stage: .film,
                 modified: { paramsMoved([.halationAmount, .halationScatter], $0) || $0.antihalationRemoved },
                 reset: { resetParams([.halationAmount, .halationScatter], $0) { $0.antihalationRemoved = nil } },
                 panel: { m, _ in AnyView(ToolScroll {
                     sliders([.halationAmount, .halationScatter], m)
                     ToggleRow(title: String(localized: "移除防光晕层"), note: String(localized: "实验：像 CineStill 那样去掉片基的防光晕层，亮处的红色光晕会明显变强"),
                               isOn: Binding(get: { m.antihalationRemoved }, set: { m.setAntihalationRemoved($0) }))
                 }) }),
        EditTool(id: "grain", title: String(localized: "颗粒"), stage: .film,
                 modified: { paramsMoved([.grainAmount], $0) },
                 reset: { resetParams([.grainAmount], $0) },
                 panel: { m, _ in AnyView(ToolScroll { sliders([.grainAmount], m) }) }),
        EditTool(id: "couplers", title: String(localized: "成色剂"), stage: .film,
                 modified: { paramsMoved([.couplersAmount], $0) },
                 reset: { resetParams([.couplersAmount], $0) },
                 panel: { m, _ in AnyView(ToolScroll {
                     if m.catalog.isMonochrome(m.filmStock) {
                         Note(String(localized: "黑白胶片只有一层银盐，没有彩色成色剂。"))
                     } else {
                         sliders([.couplersAmount], m)
                         Note(String(localized: "成色剂让彩色胶片的各层互相抑制：越高，颜色越分离、边缘越锐。"))
                     }
                 }) }),
        EditTool(id: "develop", title: String(localized: "显影"), stage: .film,
                 modified: { paramsMoved([.densityCurveGamma], $0) },
                 reset: { resetParams([.densityCurveGamma], $0) },
                 panel: { m, _ in AnyView(ToolScroll {
                     sliders([.densityCurveGamma], m)
                     Note(String(localized: "胶片的密度曲线：低于 1 更平、宽容度更大，高于 1 更硬。"))
                 }) }),
        EditTool(id: "edge", title: String(localized: "片边"), stage: .film,
                 modified: { $0.filmBorderEnabled || !$0.edgeText.isEmpty },
                 reset: { m in m.edit { $0.filmBorderEnabled = false; $0.edgeText = nil
                     $0.overscanFormat = FilmGateCatalog.automaticID; $0.stripOrientation = FilmStripOrientation.automatic.rawValue } },
                 panel: { m, _ in AnyView(FilmEffectsSheet(model: m, part: .border)) }),
        EditTool(id: "date", title: String(localized: "日期"), stage: .film,
                 modified: { $0.dateBackEnabled },
                 reset: { $0.setDateBackEnabled(false) },
                 panel: { m, _ in AnyView(FilmEffectsSheet(model: m, part: .date)) }),

        // 相纸
        EditTool(id: "paper", title: String(localized: "相纸"), stage: .paper,
                 modified: { $0.isSilverPrint && $0.paperGrade != PaperGrade.standard },
                 reset: { $0.setPaperGrade(PaperGrade.standard) },
                 panel: { m, ctx in AnyView(StockPanel(model: m, papers: true, browse: { ctx.browseStocks(true) })) }),
        EditTool(id: "enlarger", title: String(localized: "印放"), stage: .paper,
                 modified: { paramsMoved([.printBrightness, .yFilterShift, .mFilterShift, .preflash], $0) },
                 reset: { resetParams([.printBrightness, .yFilterShift, .mFilterShift, .preflash], $0) },
                 panel: { m, _ in AnyView(ToolScroll { sliders([.printBrightness, .yFilterShift, .mFilterShift, .preflash], m) }) }),
        EditTool(id: "output", title: String(localized: "输出"), stage: .paper,
                 modified: { paramsMoved([.scanFilm, .digitalIntermediate], $0) },
                 reset: { resetParams([.scanFilm, .digitalIntermediate], $0) },
                 panel: { m, _ in AnyView(ToolScroll { sliders([.scanFilm, .digitalIntermediate], m) }) }),

        // 后期
        EditTool(id: "light", title: String(localized: "光线"), stage: .finish,
                 modified: { !$0.adjustments.isNeutral(.light) },
                 reset: { m in var a = m.adjustments; a.reset(.light); m.setAdjustments(a) },
                 panel: { m, _ in AnyView(FinishPanel(model: m, fixedTool: .light)) }),
        EditTool(id: "colour", title: String(localized: "色彩"), stage: .finish,
                 modified: { let a = $0.adjustments; return a.temperature != 0 || a.tint != 0 || a.saturation != 0 || a.vibrance != 0 },
                 reset: { m in var a = m.adjustments; a.temperature = 0; a.tint = 0; a.saturation = 0; a.vibrance = 0; m.setAdjustments(a) },
                 panel: { m, _ in AnyView(FinishPanel(model: m, fixedTool: .colour)) }),
        EditTool(id: "hsl", title: "HSL", stage: .finish,
                 modified: { !$0.adjustments.hsl.isNeutral },
                 reset: { m in var a = m.adjustments; a.hsl = HSLSet(); m.setAdjustments(a) },
                 panel: { m, _ in AnyView(FinishPanel(model: m, fixedTool: .hsl)) }),
        EditTool(id: "curve", title: String(localized: "曲线"), stage: .finish,
                 modified: { !$0.adjustments.curves.isIdentity },
                 reset: { m in var a = m.adjustments; a.curves = CurveSet(); m.setAdjustments(a) },
                 panel: { m, _ in AnyView(FinishPanel(model: m, fixedTool: .curve)) }),
        EditTool(id: "balance", title: String(localized: "色彩平衡"), stage: .finish,
                 modified: { !$0.adjustments.colorBalance.isNeutral },
                 reset: { m in var a = m.adjustments; a.colorBalance = ColorBalance(); m.setAdjustments(a) },
                 panel: { m, _ in AnyView(FinishPanel(model: m, fixedTool: .balance)) }),
        EditTool(id: "local", title: String(localized: "局部"), stage: .finish,
                 modified: { $0.recipe.localAdjustments?.isEmpty == false },
                 reset: { m in m.edit { $0.localAdjustments = nil }; m.selectedLocal = nil },
                 panel: { m, _ in AnyView(LocalPanel(model: m)) }),
        EditTool(id: "mixer", title: String(localized: "通道混合"), stage: .finish,
                 modified: { !$0.adjustments.channelMixer.isNeutral },
                 reset: { m in var a = m.adjustments; a.channelMixer = ChannelMixer(); m.setAdjustments(a) },
                 panel: { m, _ in AnyView(FinishPanel(model: m, fixedTool: .mixer)) }),
        EditTool(id: "watermark", title: String(localized: "水印"), stage: .finish,
                 modified: { $0.recipe.watermarks != nil },
                 reset: { m in m.edit { $0.watermarks = nil } },
                 panel: { m, _ in AnyView(WatermarkPanel(model: m, shelf: m.watermarkShelf)) }),
        EditTool(id: "hdr", title: "HDR", stage: .finish,
                 modified: { $0.recipe.hdr == true },
                 reset: { $0.setHDREnabled(false) },
                 panel: { m, _ in AnyView(ToolScroll {
                     ToggleRow(title: String(localized: "启用 HDR"),
                               note: String(localized: "相纸的高光在 HDR 屏幕上亮过白色：按这卷胶片和相纸的肩部算出每个像素该亮多少（引擎给的曲线）。导出 JPEG / HEIF 时附上增益图，“照片”里看是 HDR，不支持的地方照常显示 SDR。"),
                               isOn: Binding(get: { m.recipe.hdr == true }, set: { m.setHDREnabled($0) }))
                     if m.recipe.hdr == true {
                         switch m.hdrAnswer {
                         case .refused?: Note(String(localized: "这卷胶片和相纸的组合引擎算不出 HDR 曲线，画面保持 SDR。"))
                         case .curve?: Note(UIScreen.main.potentialEDRHeadroom > 1.01
                                            ? String(localized: "屏幕能亮过白色约 \(String(format: "%.1f", log2(UIScreen.main.potentialEDRHeadroom))) 档；曲线最多 2 档。")
                                            : String(localized: "这块屏幕现在不能显示 HDR（低电量模式？），导出的增益图不受影响。"))
                         case nil: Note(String(localized: "正在向引擎要这张的 HDR 曲线…"))
                         }
                     }
                 }) }),
    ]
}

// MARK: - the deck

struct EditorDeck: View {
    @ObservedObject var model: ViewModel
    let context: EditContext
    /// Held by the page, so the top bar's film capsule can bring the deck to the film.
    @Binding var stage: EditStage
    @Binding var chosen: [EditStage: String]

    private var noFilm: Bool { model.recipe.noFilm == true }
    private var tools: [EditTool] { EditTool.tools(in: current, noFilm: noFilm) }
    /// The stages with something to do: under 无胶片 镜头 · 曝光 · 相纸 go (nothing of them reaches the picture).
    private var stages: [EditStage] { EditStage.allCases.filter { !EditTool.tools(in: $0, noFilm: noFilm).isEmpty } }
    /// The stage shown: a hidden one (left there by another photo) reads as the film.
    private var current: EditStage { stages.contains(stage) ? stage : .film }
    private var tool: EditTool? { tools.first { $0.id == chosen[current] } ?? tools.first }

    var body: some View {
        VStack(spacing: 0) {
            toolRow
            Group {
                if let tool { tool.panel(model, context) }
            }
            .frame(height: 196)
            .frame(maxWidth: .infinity)
            .id(tool?.id)
            stageRow
        }
        // Turning 无胶片 on while on a stage it hides: back to the film, where it is turned off again.
        .onChange(of: noFilm) { _, on in
            if on, !stages.contains(stage) { withAnimation(.easeOut(duration: 0.15)) { stage = .film } }
        }
        .labGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var toolRow: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tools) { t in
                        let on = t.id == tool?.id
                        Button { chosen[current] = t.id } label: {
                            HStack(spacing: 3) {
                                Text(t.title)
                                if t.modified(model) { Circle().fill(Color.labRed).frame(width: 4, height: 4) }
                            }
                            .font(.system(size: 12, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Color.labCream : Color.secondary)
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(on ? Color.white.opacity(0.1) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
            if let tool, let reset = tool.reset {
                let moved = tool.modified(model)
                Button { reset(model) } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(moved ? Color.labCream : Color.secondary.opacity(0.35))
                .disabled(!moved)
                .accessibilityLabel(String(localized: "重置\(tool.title)"))
                .padding(.trailing, 6)
            }
        }
        .padding(.top, 8)
    }

    private var stageRow: some View {
        HStack(spacing: 0) {
            ForEach(stages) { s in
                let on = s == current
                let moved = EditTool.tools(in: s, noFilm: noFilm).contains { $0.modified(model) }
                Button { withAnimation(.easeOut(duration: 0.15)) { stage = s } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: s.symbol)
                            .font(.system(size: 15, weight: on ? .semibold : .regular))
                            .overlay(alignment: .topTrailing) {
                                if moved { Circle().fill(Color.labRed).frame(width: 5, height: 5).offset(x: 4, y: -2) }
                            }
                        Text(tr(s.rawValue)).font(.system(size: 10, weight: on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? Color.labCream : Color.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(s.rawValue) + (moved ? String(localized: "，已调整") : ""))
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
}

// MARK: - building blocks for panels

/// A tool's controls, scrolling if they outgrow the panel.
struct ToolScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ToggleRow: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote)
                if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .tint(Color.labRed)
    }
}

/// A `ParamCatalog` control: a switch or a slider, written through the model.
struct ParamRow: View {
    @ObservedObject var model: ViewModel
    let control: ParamControl
    var body: some View {
        let value = Binding(get: { model.params[control.key] ?? control.defaultValue },
                            set: { model.parameterChanged(control.key, $0) })
        if control.isToggle {
            ToggleRow(title: control.title, note: control.note,
                      isOn: Binding(get: { value.wrappedValue >= 0.5 }, set: { value.wrappedValue = $0 ? 1 : 0 }))
        } else {
            ParamSlider(control: control, value: value)
        }
    }
}

/// A row of choices; the chosen one is filled.
struct ChipRow: View {
    let title: String
    let options: [(String, String)]
    let selected: String
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.footnote).frame(width: 30, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(options, id: \.0) { value, label in
                        let on = value == selected
                        Button { pick(value) } label: {
                            Text(label)
                                .font(.system(size: 11, weight: on ? .semibold : .medium))
                                .foregroundStyle(on ? Color.black : Color.labCream)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(on ? Color.labCream : Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Films or papers: two rows to scroll, every stock a tap away in 全部; a silver paper's grades above.
struct StockPanel: View {
    @ObservedObject var model: ViewModel
    let papers: Bool
    let browse: () -> Void
    @State private var comparing = false

    var body: some View {
        if papers && model.recipe.noFilm == true {
            // 无胶片 is not printed: no paper to choose.
            Text(String(localized: "无胶片：不经过相纸。选一卷胶片后，这里可以换相纸。"))
                .font(.footnote)
                .foregroundStyle(Color.labCream.opacity(0.6))
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding(.horizontal, 14)
        } else if papers && model.catalog.isSlide(model.recipe.filmStock) {
            // A slide is scanned, never printed (as the Mac app): no paper to choose.
            Text(String(localized: "反转片直接扫描，不印在相纸上，所以这里没有相纸可选。换一卷负片后可以选相纸。"))
                .font(.footnote)
                .foregroundStyle(Color.labCream.opacity(0.6))
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding(.horizontal, 14)
        } else {
            stockPanel
        }
    }

    private var stockPanel: some View {
        let stocks = papers ? model.papers : model.filmsFavouritesFirst
        let selected = papers ? model.printStock : model.recipe.noFilm == true ? "" : model.filmStock
        return VStack(spacing: 6) {
            HStack {
                if papers && model.isSilverPrint {
                    ChipRow(title: String(localized: "号数"), options: model.catalog.grades.map { ($0.name, $0.name) },
                            selected: model.paperGrade) { model.setPaperGrade($0) }
                } else {
                    Text(papers ? model.currentPaperName : model.currentLookName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.labCream)
                        .lineLimit(1)
                    Spacer()
                }
                if !papers && model.recipe.noFilm != true {
                    Button { comparing = true } label: {
                        HStack(spacing: 2) {
                            Text(String(localized: "对比"))
                            Image(systemName: "square.grid.3x3.square")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.labCream.opacity(0.8))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "用这张照片对比全部胶片"))
                    .sheet(isPresented: $comparing, onDismiss: { model.stopFilmGrid() }) {
                        FilmGridSheet(model: model) { comparing = false }
                            .presentationDetents([.large])
                            .presentationBackground(Color.labInk)
                    }
                }
                Button(action: browse) {
                    HStack(spacing: 2) {
                        Text(String(localized: "全部 \(stocks.count)"))
                        Image(systemName: "square.grid.2x2")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.labCream.opacity(0.8))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(papers ? String(localized: "查看全部相纸") : String(localized: "查看全部胶片"))
            }
            .padding(.horizontal, 14)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(58), spacing: 6), GridItem(.fixed(58))], spacing: 8) {
                        if !papers {
                            NoFilmTile(title: String(localized: "无胶片"), detail: String(localized: "原图，不经过胶片"), on: selected.isEmpty) { model.chooseNoFilm() }
                                .id("")
                        }
                        ForEach(stocks) { stock in
                            let usable = !papers || model.canPrint(on: stock.id)
                            StockTile(stock: stock, selected: stock.id == selected,
                                      recommended: papers && StockCatalog.recommendedPapers(for: model.filmStock).contains(stock.id)) {
                                if papers { model.paperChanged(stock.id) } else { model.filmChanged(stock.id) }
                            }
                            .disabled(!usable)
                            .opacity(usable ? 1 : 0.32)
                            .id(stock.id)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .onAppear { proxy.scrollTo(selected, anchor: .center) }
            }
        }
        .padding(.top, 6)
    }
}

/// The Decode curve: on the scene, before the film.
struct DecodeCurvePanel: View {
    @ObservedObject var model: ViewModel
    @State private var channel: CurveChannel = .rgb

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                ForEach(CurveChannel.allCases) { c in
                    Button { channel = c } label: {
                        Text(c.tab)
                            .font(.system(size: 11, weight: channel == c ? .semibold : .medium))
                            .foregroundStyle(channel == c ? Color.labCream : Color.secondary)
                            .frame(width: 44, height: 24)
                            .background(channel == c ? Color.white.opacity(0.1) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            CurveEditor(curve: Binding(get: { model.sceneCurve[channel] },
                                       set: { var c = model.sceneCurve; c[channel] = $0; model.setSceneCurve(c) }),
                        tint: channel.tint)
                .frame(width: 150, height: 150)
            Note(String(localized: "作用在曝光到胶片之前：横轴是场景亮度（中灰上下各 4 档），颗粒、光晕和相纸会照常跟着变。"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}


/// 胶片 › 对比: this photo through every film, on each film's own paper, in a grid by maker; a tap takes the film.
struct FilmGridSheet: View {
    @ObservedObject var model: ViewModel
    let close: () -> Void

    var body: some View {
        let groups = Stock.grouped(model.films)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.0) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 10) {
                                ForEach(group.1) { card($0) }
                            }
                            .padding(.horizontal, 12)
                        } header: {
                            Text(group.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.labInk.opacity(0.95))
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationTitle(String(localized: "对比胶片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.filmGridRunning {
                        Text(String(localized: "冲洗中 \(model.filmGrid.count)/\(model.films.count)"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button(String(localized: "完成"), action: close) }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.startFilmGrid() }
    }

    private func card(_ stock: Stock) -> some View {
        let on = stock.id == model.filmStock && model.recipe.noFilm != true
        return Button {
            model.filmChanged(stock.id)
            close()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Color.labPanel
                    if let image = model.filmGrid[stock.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.labRed : Color.clear, lineWidth: 2))
                Text(stock.name.replacingOccurrences(of: stock.brand + " ", with: ""))
                    .font(.caption2)
                    .foregroundStyle(on ? Color.labCream : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .buttonStyle(.plain)
    }
}
