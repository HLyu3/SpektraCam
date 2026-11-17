//  PhotoLibrary.swift — the photographs the app keeps, and the look each one has.
//
//  The library is deliberately app-owned rather than a list of Photos
//  identifiers: a picked RAW has to stay readable after the picker result goes
//  away, and the wall has to render without asking the Photos database for
//  permission again. Originals live in Application Support, one thumbnail per
//  photo beside them, and a small JSON manifest carries the recipe.
//
//  A recipe is the *look*, not the photograph: film, paper, adjustments and
//  the physical film-edge/date-back choices. It never carries a crop, a date
//  or a person's shooting data, so pasting it across a selection does not
//  make every picture claim it was taken on the same day.

import Foundation
import UIKit
import UniformTypeIdentifiers

/// Everything needed to reproduce one look on another photograph.
struct PhotoRecipe: Codable, Equatable, Sendable {
    var filmStock: String
    var printStock: String
    var params: [String: Double]
    var filmBorderEnabled: Bool
    var overscanFormat: String
    var stripOrientation: String
    var dateBackEnabled: Bool
    var dateBackStyle: String
    var dateBackPlacement: String
    var dateBackCorner: String
    /// Layer 2 (后期). Absent in older manifests and for an untouched photo.
    var adjustments: Adjustments? = nil
    /// Multigrade contrast grade ("00"…"5") for a black-and-white print; nil is grade 2.
    var paperGrade: String? = nil
    /// The film edge's own words; nil prints the film's name.
    var edgeText: String? = nil
    /// Experiment: the film without its anti-halation layer.
    var antihalationRemoved: Bool? = nil
    /// The meter: "balanced" (nil), "center", "protect_highlights", "protect_shadows", or "manual".
    var exposureMethod: String? = nil
    /// A lens filter by the engine's name ("w8", "w25"…); nil for none.
    var lensFilter: String? = nil
    /// The film's long edge in mm when there is no film edge to decide it; nil is 35 mm.
    var filmFormatMM: Double? = nil
    /// The Decode curve: a tone curve on the scene before it is exposed onto the film.
    var sceneCurve: CurveSet? = nil
    /// Light leak (`leak_kind`: auto, band, wash, spot; nil = off) and its strength, 0…4.
    var leakKind: String? = nil
    var leakAmount: Double? = nil
    /// 边缘烧灼 (engine 2.4.1 `leak_edge`): the edge burn's own strength, 0…4, beside any kind; nil = off.
    var leakEdge: Double? = nil
    /// 随机 (`leak_seed`): the leak's own place and shape; nil = the camera body's (`overscan_camera_seed`).
    var leakSeed: Int? = nil
    /// Diffusion filter on the lens (`diffusion_filter_family`; nil = none) and its grade, 1/8…2.
    var diffusionFamily: String? = nil
    var diffusionStrength: Double? = nil
    /// Lens character (`LensCharacter` raw value; nil = none) and how much of it, 0…1.
    var lensCharacter: String? = nil
    var lensAmount: Double? = nil
    /// Enable HDR: the print's highlights past white on an HDR screen and a gain map in JPEG / HEIF exports.
    /// Not sent to the engine; nil is off.
    var hdr: Bool? = nil
    /// 水印 over the finished picture (`Edit/Watermark.swift`); never on the wire. nil = none.
    var watermarks: [WatermarkPlacement]? = nil
    /// 白平衡 at the decode (`Edit/SceneBalance.swift`): r, g, b gains on the linear frame before the engine. nil = as shot.
    var sceneBalance: [Double]? = nil
    /// 自动置位 (the engine's Scene Latitude fit, solved per photo): nil = off, as the Mac app's default (the owner:
    /// the same look as the Mac, sky and all); true = on. Ignored while the manual 场景置位 is on. Not a wire key: a
    /// solve step (`SpektraEngine.solve(placement:)`).
    var autoPlacement: Bool? = nil
    /// Whether the engine places this photo's scene itself.
    var placesAutomatically: Bool { autoPlacement == true && (params["scene_latitude_active"] ?? 0) < 0.5 && noFilm != true }
    /// 无胶片: the original as the system renders it (plus 后期), no engine. nil is off.
    var noFilm: Bool? = nil

    /// The film as the library names and groups it: "" for 无胶片.
    var filmID: String { noFilm == true ? "" : filmStock }

    /// `scene_curve` on the wire: five rows (rgb, luma, r, g, b) of 129 samples, "" for none
    /// (upstream `FilmParams.sceneCurveWire`). Sent always, so taking a curve off reaches the session.
    static func sceneCurveWire(_ curve: CurveSet?) -> String {
        guard let curve, !curve.isIdentity else { return "" }
        return CurveChannel.allCases.flatMap { curve.table($0, size: 129) }
            .map { String(format: "%.5f", min(max($0, 0), 1)) }.joined(separator: ",")
    }

    /// The meter a new photograph starts with: 相机 (the camera's own exposure, `LibraryPhoto.cameraEV`). Before it,
    /// 保高光. "Balanced" lifted a dark room with white cabinets about 2 EV
    /// and blew them out (a 4× kitchen shot, 2026-11-16); protect-highlights fixed it and left an ordinary scene
    /// exactly as balanced develops it (measured through the engine). Older photos keep their meter.
    static let newPhotoMeter = "camera"     // 相机测光 (a choice; was camera shots' default until 2026-11-17)
    /// A camera shot's meter (`ViewModel.rollRecipe`): 保高光, the sky held.
    static let shotMeter = "protect_highlights"

    /// The look a newly imported photograph starts with.
    static var standard: PhotoRecipe {
        var defaults: [String: Double] = [:]
        for control in ParamCatalog.all { defaults[control.key] = control.defaultValue }
        var r = PhotoRecipe(filmStock: StockCatalog.defaultFilm,
                           printStock: StockCatalog.defaultPaper,
                           params: defaults,
                           filmBorderEnabled: false,
                           overscanFormat: FilmGateCatalog.automaticID,
                           stripOrientation: FilmStripOrientation.automatic.rawValue,
                           dateBackEnabled: false,
                           dateBackStyle: DateBackStyle.lcd.rawValue,
                           dateBackPlacement: DateBackPlacement.frame.rawValue,
                           dateBackCorner: DateBackCorner.br.rawValue)
        return r          // imports meter with the engine (均衡, as upstream); camera shots set 相机 (`rollRecipe`)
    }

    /// Parameters from an older library may not have every key this build
    /// knows. Fill them from the catalogue rather than letting a missing slider
    /// fall back to an engine default the UI does not show.
    var normalizedParams: [String: Double] {
        var merged: [String: Double] = [:]
        for control in ParamCatalog.all { merged[control.key] = control.defaultValue }
        for (key, value) in params { merged[key] = value }
        return merged
    }

    /// The same complete delta every open path uses. `imageAspect` resolves an
    /// automatic gate from *this* photograph, not from whichever photograph
    /// happened to be open when the recipe was copied.
    func engineDelta(filmName: String,
                     frameNumber: Int = 12,
                     imageAspect: CGFloat,
                     stamp: Date,
                     shootingData: String,
                     cameraEV: Double? = nil) -> [String: ParamValue] {
        var delta = ParamDefaults.delta(film: filmStock, paper: printStock)
        for (key, value) in normalizedParams {
            if let control = ParamCatalog.control(for: key) {
                if let v = control.wire(value) { delta[key] = v }
            } else {
                delta[key] = .number(value)
            }
        }
        let method = exposureMethod ?? "balanced"
        if method == "camera", let cameraEV {
            // 相机测光: developed at the exposure the camera metered (`LibraryPhoto.cameraEV`), not re-metered; the
            // photo's own compensation (the viewfinder drag, the slider) on top.
            delta["auto_exposure"] = .bool(false)
            let user = params[FilmParam.exposureCompensation.key] ?? 0
            delta[FilmParam.exposureCompensation.key] = .number(min(max(cameraEV + user, -8), 8))
        } else if method == "camera" {
            // Not measured yet (it is, before any develop): the safe meter meanwhile.
            delta["auto_exposure"] = .bool(true)
            delta["auto_exposure_method"] = .string("protect_highlights")
        } else {
            delta["auto_exposure"] = .bool(method != "manual")
            if method != "manual" { delta["auto_exposure_method"] = .string(method) }
        }
        delta["camera_filter"] = .string(lensFilter ?? "")
        delta["scene_curve"] = .string(Self.sceneCurveWire(sceneCurve))
        // Sent always, so turning either off reaches an open session (upstream `sometimesSent`).
        delta["leak_kind"] = .string(leakKind ?? "off")
        delta["leak_amount"] = .number(min(max(leakAmount ?? 1, 0), 4))
        delta["leak_rate"] = .number(1)          // one photograph: its leak always shows
        delta["leak_front"] = .number(-1)        // where it comes from: the camera body's own
        // Sent always (0 = off / the body's own), so taking either away reaches an open session.
        delta["leak_edge"] = .number(min(max(leakEdge ?? 0, 0), 4))
        delta["leak_seed"] = .number(Double(leakSeed ?? 0))
        delta["diffusion_filter_active"] = .bool(diffusionFamily != nil)
        delta["diffusion_filter_family"] = .string(diffusionFamily ?? "black_pro_mist")
        delta["diffusion_filter_strength"] = .number(min(max(diffusionStrength ?? 0.5, 0), 2))
        if let character = lensCharacter.flatMap(LensCharacter.init) {
            for (k, v) in character.preset.wire(amount: lensAmount ?? 1) { delta[k] = v }
        } else {
            delta["lens_aberrations_active"] = .bool(false)
        }
        let params = normalizedParams
        // The couplers' switch follows their amount, so 0 is a structural bypass.
        delta["dir_couplers_active"] = .bool((params[FilmParam.couplersAmount.key] ?? 1) > 0)

        let gate = FilmGateCatalog.resolve(selection: overscanFormat, imageAspect: imageAspect)
        // Grain and halation are sized against the frame: the film edge's gate decides it, else the format picker.
        delta["film_format_mm"] = .number(filmBorderEnabled ? gate.longEdgeMM : (filmFormatMM ?? 36))
        delta["overscan_active"] = .bool(filmBorderEnabled)
        delta["overscan_format"] = .string(gate.id)
        delta["overscan_mode"] = .string("strip")
        delta["overscan_gate"] = .string("auto")
        delta["overscan_holes"] = .string("white")
        delta["overscan_carrier"] = .string("none")
        delta["overscan_edge_text"] = .string(edgeText.flatMap { $0.isEmpty ? nil : $0.uppercased() } ?? filmName.uppercased())
        delta["antihalation_removed"] = .bool(antihalationRemoved ?? false)

        // Black and white (upstream `StockCatalog.silver`): one grain layer on a silver film; on a
        // silver paper no extended range, and the grade's filter pack, which the engine's table lacks.
        let catalog = StockCatalog.shared
        if catalog.isMonochrome(filmStock) { delta["grain_sublayers_active"] = .bool(false) }
        // Less enlarger light prints brighter: print_exposure = 2^-stops (upstream `FilmParams.printExposure`).
        let brightness = pow(2.0, -(params[FilmParam.printBrightness.key] ?? 0))
        delta["print_exposure"] = .number(min(max(brightness, 0.05), 20))
        if catalog.isMonochrome(printStock) {
            delta["extended_dynamic_range"] = .bool(false)
            if catalog.isMonochrome(filmStock), let g = catalog.grade(paperGrade ?? PaperGrade.standard) {
                delta["c_filter_neutral"] = .number(0)
                delta["m_filter_neutral"] = .number(g.magenta)
                delta["y_filter_neutral"] = .number(g.yellow)
                delta["print_exposure"] = .number(min(max(g.printExposure * brightness, 0.05), 20))
            }
        }
        delta["overscan_frame_number"] = .number(Double(min(max(frameNumber, 0), 99)))
        delta["overscan_camera_seed"] = .number(Double(CameraBody.number))
        delta["overscan_frame_seed"] = .number(Double(frameNumber) + 10)
        delta["overscan_fog"] = .number(1)
        delta["overscan_leaks"] = .number(0)

        let style = DateBackStyle(rawValue: dateBackStyle) ?? .lcd
        let placement = DateBackPlacement(rawValue: dateBackPlacement) ?? .frame
        let corner = DateBackCorner(rawValue: dateBackCorner) ?? .br
        let dateActive = dateBackEnabled && gate.supportsDateBack
        delta["date_imprint_active"] = .bool(dateActive)
        delta["date_imprint_text"] = .string(Self.dateStamp(stamp))
        delta["date_imprint_data_text"] = .string(shootingData)
        delta["date_imprint_placement"] = .string(filmBorderEnabled ? placement.rawValue : DateBackPlacement.frame.rawValue)
        delta["date_imprint_style"] = .string(style.rawValue)
        delta["date_imprint_corner"] = .string(corner.rawValue)
        delta["date_imprint_ev"] = .number(3.5)
        delta["date_imprint_size"] = .number(1)
        delta["date_imprint_inset_x"] = .number(3)
        delta["date_imprint_inset_y"] = .number(2.4)
        return delta
    }

    static func dateStamp(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day], from: date)
        return String(format: "'%02d %02d %02d",
                      (parts.year ?? 2000) % 100,
                      parts.month ?? 1,
                      parts.day ?? 1)
    }
}

/// One photograph on the wall. The image is already decoded for display; the
/// original stays on disk so opening it or exporting it keeps full quality.
struct LibraryPhoto: Identifiable {
    let id: UUID
    var name: String
    var fileName: String
    var typeIdentifier: String?
    var pixelWidth: Int
    var pixelHeight: Int
    /// The source's display aspect before a film gate crops it. A rendered
    /// thumbnail may itself be a wide strip, so its size cannot be used to
    /// decide the next crop.
    var sourceAspect: Double
    var createdAt: Date
    var recipe: PhotoRecipe
    /// Crop and straighten belong to the photograph, not to the look (a pasted recipe leaves them).
    var crop: FrameCrop? = nil
    /// A half-frame pair: which two photographs this piece was composed from.
    var pair: PairSpec? = nil
    var favorite = false
    /// Shot with the app's camera (not imported).
    var captured = false
    /// The frame number on its film edge (1…36), given when it joined the wall.
    var frameNumber: Int? = nil
    /// A photo read in place from the system Photos library (no copy: `fileName` is empty).
    var assetID: String? = nil
    /// When it was last exported to Photos: its developed print exists outside SpektraLab.
    var exportedAt: Date? = nil
    /// When the picture was taken (EXIF, or the Photos asset's date); nil until read (`fillCaptureDates`).
    var capturedAt: Date? = nil
    /// The file it was imported from ("name|size|mtime"): importing that file again skips it while this photo
    /// is in the library; once deleted, it can come in again.
    var importedFrom: String? = nil
    /// 相机测光: how many EV this photo's linear decode sits under the camera's own develop of it (Apple's rendering,
    /// log-average brightness) — the exposure the camera metered. Measured once (`ViewModel.ensureCameraEV`).
    var cameraEV: Double? = nil
    /// The print last exported to Photos (its asset id) and the look it was developed with (`exportLookKey`): an
    /// export finds it and asks whether to replace it, saying whether the look changed since.
    var exportedAssetID: String? = nil
    var exportedLook: String? = nil
    var isEdited: Bool
    var thumbnail: UIImage

    var isRAW: Bool { typeIdentifier.flatMap(UTType.init)?.conforms(to: .rawImage) ?? false }

    /// The thumbnail has already been through ImageIO's orientation transform,
    /// so its size is the only aspect that is correct for both portrait and
    /// landscape source files.
    var aspect: Double {
        guard thumbnail.size.height > 0 else { return 3.0 / 2.0 }
        return Double(thumbnail.size.width / thumbnail.size.height)
    }

    var megapixels: Double {
        Double(pixelWidth * pixelHeight) / 1_000_000
    }
}

/// The manifest's row. `thumbnail` is not stored in JSON; it is the JPEG next
/// to the original, named from the id.
struct LibraryManifestEntry: Codable {
    var id: UUID
    var name: String
    var fileName: String
    var typeIdentifier: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var sourceAspect: Double
    var createdAt: Date
    var recipe: PhotoRecipe
    var crop: FrameCrop? = nil
    var pair: PairSpec? = nil
    var favorite: Bool? = nil
    var captured: Bool? = nil
    var frameNumber: Int? = nil
    var assetID: String? = nil
    var exportedAt: Date? = nil
    /// When the picture was taken (EXIF, or the Photos asset's date); nil until read (`fillCaptureDates`).
    var capturedAt: Date? = nil
    var importedFrom: String? = nil
    var cameraEV: Double? = nil
    var exportedAssetID: String? = nil
    var exportedLook: String? = nil
    var isEdited: Bool
}

enum LibraryThumbnail {
    static let maxPixel: CGFloat = 900

    /// Decode a display thumbnail without touching the engine. ImageIO's
    /// thumbnail path is also the cheapest way to honour EXIF orientation on
    /// JPEG/HEIC/RAW containers.
    static func from(data: Data, maxPixel: CGFloat = maxPixel) -> (UIImage, Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ]
        let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard let cg else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? cg.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? cg.height
        return (UIImage(cgImage: cg), width, height)
    }

    static func downscale(_ image: UIImage, maxPixel: CGFloat = maxPixel) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return image }
        let factor = min(1, maxPixel / max(width, height))
        if factor >= 1 { return image }
        let size = CGSize(width: width * factor, height: height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func downscale(_ cgImage: CGImage, maxPixel: CGFloat = maxPixel) -> UIImage {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return UIImage(cgImage: cgImage) }
        let factor = min(1, maxPixel / max(width, height))
        let size = CGSize(width: width * factor, height: height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func saveJPEG(_ image: UIImage, to url: URL) throws {
        guard let data = image.jpegData(compressionQuality: 0.86) else {
            throw DecodeError.unreadable("缩略图无法编码")
        }
        try data.write(to: url, options: .atomic)
    }

    static func placeholder() -> UIImage {
        let size = CGSize(width: 600, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let symbol = UIImage(systemName: "photo")?.withTintColor(.white.withAlphaComponent(0.28),
                                                                     renderingMode: .alwaysOriginal)
            let side = size.width * 0.24
            symbol?.draw(in: CGRect(x: (size.width - side) / 2,
                                    y: (size.height - side) / 2,
                                    width: side, height: side))
        }
    }
}

/// The camera the film went through: its body number seeds the film edge's camera-specific marks,
/// and the next frame number is what the next photo on the wall is exposed as.
enum CameraBody {
    private static let bodyKey = "SpektraLab.cameraBody"
    private static let frameKey = "SpektraLab.nextFrame"

    static var number: Int {
        get { UserDefaults.standard.object(forKey: bodyKey) as? Int ?? 7 }
        set { UserDefaults.standard.set(newValue, forKey: bodyKey) }
    }

    static func changeBody() { number = Int.random(in: 1...999) }

    static var nextFrame: Int { UserDefaults.standard.object(forKey: frameKey) as? Int ?? 1 }

    /// The frame the next photo takes; the roll winds on, 36 to a roll.
    static func takeFrame() -> Int {
        let n = nextFrame
        UserDefaults.standard.set(n % 36 + 1, forKey: frameKey)
        return n
    }

    /// 过片: skip one frame.
    static func advance() { _ = takeFrame() }
}

/// 镜头风格: a named lens, its twelve `lens_*` numbers at 100 % (upstream `Model/LensEdge.swift`).
enum LensCharacter: String, CaseIterable, Sendable {
    case swirl = "helios44", petzval = "petzval", vintage = "vintage_soft", toy = "plastic"

    var title: String {
        switch self {
        case .swirl: "旋焦"
        case .petzval: "Petzval"
        case .vintage: "老镜"
        case .toy: "玩具镜"
        }
    }

    var preset: LensPreset {
        switch self {
        case .swirl: LensPreset(fieldCurvatureUM: 45, astigmatismUM: 70, fieldExponent: 2, comaUM: 25,
                                sphericalAmount: 0.08, sphericalUM: 60)
        case .petzval: LensPreset(fieldCurvatureUM: 70, astigmatismUM: 100, fieldExponent: 3, sharpRadius: 0.3)
        case .vintage: LensPreset(fieldCurvatureUM: 25, comaUM: 60, sphericalAmount: 0.2, sphericalUM: 80)
        case .toy: LensPreset(fieldCurvatureUM: 35, sphericalAmount: 0.25, sphericalUM: 120, lateralCAR: 1.5,
                              lateralCAB: -1.5, locaUM: 10, locaSign: "purple")
        }
    }
}

struct LensPreset: Sendable {
    var fieldCurvatureUM = 0.0, astigmatismUM = 0.0, fieldExponent = 2.0, sharpRadius = 0.0
    var comaUM = 0.0, sphericalAmount = 0.0, sphericalUM = 60.0
    var lateralCAR = 0.0, lateralCAB = 0.0, locaUM = 0.0, locaSign = "purple", locaHighlightGate = 1.0

    /// At `amount` the blurs, fringes and glow scale; the field's shape is the lens's own. Upstream stops at 1;
    /// this goes to 3, because the blurs are in µm on the film and at the preview's ~18 µm a pixel a 100 %
    /// lens moves the corners by two or three pixels — there but hard to see. The engine's own ranges still clamp.
    func wire(amount: Double) -> [(String, ParamValue)] {
        let a = min(max(amount, 0), 3)
        func c(_ v: Double, _ r: ClosedRange<Double>) -> ParamValue { .number(min(max(v, r.lowerBound), r.upperBound)) }
        return [
            ("lens_aberrations_active", .bool(true)),
            ("lens_field_curvature_um", c(fieldCurvatureUM * a, 0...120)),
            ("lens_astigmatism_um", c(astigmatismUM * a, -120...120)),
            ("lens_field_exponent", c(fieldExponent, 1...4)),
            ("lens_sharp_radius", c(sharpRadius, 0...0.8)),
            ("lens_coma_um", c(comaUM * a, -150...150)),
            ("lens_spherical_amount", c(sphericalAmount * a, 0...0.6)),
            ("lens_spherical_um", c(sphericalUM, 10...400)),
            ("lens_lateral_ca_r", c(lateralCAR * a, -3...3)),
            ("lens_lateral_ca_b", c(lateralCAB * a, -3...3)),
            ("lens_loca_um", c(locaUM * a, 0...30)),
            ("lens_loca_sign", .string(locaSign)),
            ("lens_loca_highlight_gate", c(locaHighlightGate, 0...1)),
        ]
    }
}
