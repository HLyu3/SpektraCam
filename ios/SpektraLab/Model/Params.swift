//  Params.swift — the engine's parameters, as Swift values.
//
//  The engine's surface is JSON (spk_engine.h rule 3), so every control in the
//  app is a key in a delta object. This file is the typed side of that: it
//  names the keys the app drives, gives them ranges and units, and turns a
//  slider's value into the JSON the engine wants.
//
//  **The key names are the engine's, not ours.** They come from the upstream
//  parameter schema (`spk_params_schema`), and the engine refuses a key it does
//  not know. So a rename here is a behaviour change, not a refactor.

import Foundation

/// One parameter value, as the engine's JSON sees it.
enum ParamValue: Codable, Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        throw DecodingError.dataCorruptedError(in: container,
                                              debugDescription: "not a number, bool or string")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }

    var doubleValue: Double? {
        if case .number(let v) = self { return v }
        if case .bool(let v) = self { return v ? 1 : 0 }
        return nil
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

/// The parameters this app drives, with their ranges.
///
/// These are the ones the Android port drives too, and the ones the engine
/// models physically. Note what is *not* here: aperture, shutter speed and
/// ISO are not simulation inputs in this engine — they are metadata the date
/// back prints. Exposure is `exposure_compensation_ev` plus `auto_exposure`;
/// white balance is the enlarger's filter pack, not a camera WB.
enum FilmParam: String, CaseIterable, Sendable {
    /// Which film stock. A profile name; the engine loads
    /// `<resources>/profiles/<name>.json`.
    case filmStock = "film_stock"
    /// Which paper. Same scheme.
    case printStock = "print_stock"
    /// Exposure compensation in stops.
    case exposureCompensation = "exposure_compensation_ev"
    /// Whether the engine computes the exposure itself.
    case autoExposure = "auto_exposure"
    /// Grain strength, 0…1.
    case grainAmount = "grain_amount"
    /// Whether the grain layer is on.
    case grainActive = "grain_active"
    /// Halation strength, 0…1.
    case halationAmount = "halation_amount"
    case halationActive = "halation_active"
    /// Veiling glare strength, 0…1.
    case glareAmount = "glare_amount"
    case glareActive = "glare_active"
    /// The enlarger's filter pack, as the M/Y shifts the engine models.
    case mFilterShift = "m_filter_shift"
    case yFilterShift = "y_filter_shift"
    /// The print's density curve gamma.
    case densityCurveGamma = "density_curve_gamma"
    /// UI stops, brighter positive; sent as `print_exposure = 2^-stops` (never on the wire itself).
    case printBrightness = "print_brightness_stops"
    case preflash = "preflash_exposure"
    case halationScatter = "halation_scatter_amount"
    case couplersAmount = "dir_couplers_amount"
    case sceneLatitudeActive = "scene_latitude_active"
    case highlightRoom = "scene_latitude_highlight_room"
    case shadowRoom = "scene_latitude_shadow_room"
    case scanFilm = "scan_film"
    case digitalIntermediate = "digital_intermediate"

    var key: String { rawValue }
}

/// One slider in the UI.
struct ParamControl: Identifiable, Sendable {
    let id: String
    let title: String
    /// The engine's key.
    let key: String
    let range: ClosedRange<Double>
    /// The value the engine starts from.
    let defaultValue: Double
    /// Whether the engine can change this in place, or has to rebuild the
    /// pipeline. The engine says which, in the `set_params` reply; this is the
    /// app's own note of the same thing, for the UI's benefit.
    let isLive: Bool
    let group: ParamGroup
    /// An on/off switch, kept as 0 / 1 like every other control.
    let isToggle: Bool
    /// One line under a switch.
    let note: String?

    init(_ param: FilmParam, title: String, range: ClosedRange<Double> = 0...1,
         defaultValue: Double, isLive: Bool = true, group: ParamGroup = .effects,
         toggle: Bool = false, note: String? = nil) {
        self.id = param.rawValue
        self.title = title
        self.key = param.rawValue
        self.range = range
        self.defaultValue = defaultValue
        self.isLive = isLive
        self.group = group
        self.isToggle = toggle
        self.note = note
    }

    /// What goes on the wire for `value`; nil for a UI-only control.
    func wire(_ value: Double) -> ParamValue? {
        if key == FilmParam.printBrightness.key { return nil }
        return isToggle ? .bool(value >= 0.5) : .number(value)
    }
}

/// The develop deck's tool groups (upstream's Print, Placement, Effects, Format).
enum ParamGroup: String, CaseIterable, Identifiable, Sendable {
    case exposure = "曝光", curve = "曲线", enlarger = "放大", placement = "置位", effects = "效果", output = "输出"
    var id: String { rawValue }
}

/// The controls the iOS app shows, in the order it shows them.
enum ParamCatalog {
    static let all: [ParamControl] = [
        ParamControl(.exposureCompensation, title: "曝光补偿", range: -3...3, defaultValue: 0, group: .exposure),

        ParamControl(.printBrightness, title: "印放亮度", range: -3...3, defaultValue: 0, group: .enlarger),
        ParamControl(.yFilterShift, title: "黄 ↔ 蓝", range: -1...1, defaultValue: 0, group: .enlarger),
        ParamControl(.mFilterShift, title: "品红 ↔ 绿", range: -1...1, defaultValue: 0, group: .enlarger),
        ParamControl(.preflash, title: "预闪", range: 0...0.2, defaultValue: 0, group: .enlarger),
        ParamControl(.densityCurveGamma, title: "密度曲线", range: 0.2...1.5, defaultValue: 1, group: .enlarger),

        ParamControl(.sceneLatitudeActive, title: "场景置位", defaultValue: 0, group: .placement, toggle: true,
                     note: "把超出相纸宽容度的高光和阴影柔和地收进来，像冲印师傅手工遮挡加光"),
        ParamControl(.highlightRoom, title: "高光收回", range: 0...6, defaultValue: 0, group: .placement),
        ParamControl(.shadowRoom, title: "阴影提起", range: 0...6, defaultValue: 0, group: .placement),

        ParamControl(.grainAmount, title: "颗粒", range: 0...2, defaultValue: 1),
        ParamControl(.halationAmount, title: "光晕", range: 0...4, defaultValue: 1),
        ParamControl(.halationScatter, title: "光晕扩散", range: 0...1, defaultValue: 1),
        ParamControl(.glareAmount, title: "眩光", range: 0...3, defaultValue: 1),
        ParamControl(.couplersAmount, title: "成色剂", range: 0...1.5, defaultValue: 1),

        ParamControl(.scanFilm, title: "扫描底片", defaultValue: 0, group: .output, toggle: true,
                     note: "不印放，直接看冲出来的底片（负片会是橙色的反相）"),
        ParamControl(.digitalIntermediate, title: "数字中间片", defaultValue: 0, group: .output, toggle: true,
                     note: "像电影后期那样把底片转成平淡的 Log 画面，留给后期调色"),
    ]

    static func control(for key: String) -> ParamControl? {
        all.first { $0.key == key }
    }
}

/// The default value of every control, as a delta the engine accepts on open.
enum ParamDefaults {
    /// The open-time switch that selects SpektraLab's product defaults.
    ///
    /// It is deliberately not a `params_schema` row, so `spk_set_params`
    /// rejects it: only `spk_open` reads it. It is what turns off the
    /// enlarger's mid-grey compensation, so `exposure_compensation_ev` moves
    /// the finished print instead of only placing the scene on the film
    /// curve. Without it the test print re-times itself for every exposure
    /// change and the slider appears to do nothing.
    static let productDefaultsKey = "product_defaults"

    static func delta(film: String, paper: String) -> [String: ParamValue] {
        var delta: [String: ParamValue] = [
            // Match the macOS preview host and its Core Image conversion:
            // linear ProPhoto in, sRGB out. The engine performs no implicit
            // colour conversion, and the app does not invent one.
            "input_color_space": .string("ProPhoto RGB"),
            "input_cctf_decoding": .bool(false),
            // Display P3 (2026-11-16): the iPhone's own photos and screen are P3, and the export defaults to it; an
            // sRGB preview pulled the film's saturated colours in and looked flatter than the exported print.
            "output_color_space": .string("Display P3"),
            "output_cctf_encoding": .bool(true),
            FilmParam.filmStock.key: .string(film),
            FilmParam.printStock.key: .string(paper),
            FilmParam.autoExposure.key: .bool(true),
            "auto_exposure_method": .string("balanced"),
            "film_format_mm": .number(36),
            FilmParam.grainActive.key: .bool(true),
            "grain_sublayers_active": .bool(true),
            FilmParam.halationActive.key: .bool(true),
            "halation_scatter_amount": .number(1),
            "halation_headroom_ev": .number(4),
            "dir_couplers_active": .bool(true),
            "dir_couplers_amount": .number(1),
            FilmParam.glareActive.key: .bool(true),
            "filter_shift_scale": .number(40),
        ]
        for control in ParamCatalog.all {
            if let v = control.wire(control.defaultValue) { delta[control.key] = v }
        }
        return delta
    }
}
