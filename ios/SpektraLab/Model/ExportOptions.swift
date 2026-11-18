//
//  ExportOptions.swift — what a full-resolution export writes, and where.
//
//  The colour space is not a conversion the app performs: it is the engine's
//  own `output_color_space`. The engine bakes sRGB, Display P3, Adobe RGB
//  (1998) and ProPhoto RGB, encodes each with its own transfer function, and
//  the CGImage is tagged with the matching Core Graphics space. So a P3 export
//  keeps the print's colours that sRGB would have clipped, without a second
//  gamut mapping on the way out.
//

import Foundation
import CoreGraphics
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case jpeg
    case heif
    case tiff16
    case png

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .heif: "HEIF"
        case .tiff16: "TIFF"
        case .png: "PNG"
        }
    }

    var detail: String {
        switch self {
        case .jpeg: String(localized: "8 位，兼容性最好：发给 Windows 电脑、网页、老设备时用")
        case .heif: String(localized: "推荐 · 10 位，体积约为 JPEG 的一半，天空等渐变更平滑；iPhone、Mac 和主流 App 都能看")
        case .tiff16: String(localized: "16 位无损（LZW），适合再修图或打印，文件很大")
        case .png: String(localized: "16 位无损，网页和大多数软件都能打开，文件很大")
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heif: "heic"
        case .tiff16: "tif"
        case .png: "png"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heif: .heic
        case .tiff16: .tiff
        case .png: .png
        }
    }

    var usesQuality: Bool { self == .jpeg || self == .heif }
}

/// One-tap export settings for the common uses, with the one we recommend first.
struct ExportPreset: Identifiable {
    let id: String
    let title: String
    let detail: String
    let format: ExportFormat
    let colorSpace: ExportColorSpace
    let quality: Double

    static let all: [ExportPreset] = [
        ExportPreset(id: "daily", title: String(localized: "日常（推荐）"), detail: "HEIF · P3 · 90", format: .heif, colorSpace: .displayP3, quality: 0.9),
        ExportPreset(id: "share", title: String(localized: "发给别人 / 上网"), detail: "JPEG · sRGB · 90", format: .jpeg, colorSpace: .sRGB, quality: 0.9),
        ExportPreset(id: "edit", title: String(localized: "再修图 / 打印"), detail: String(localized: "TIFF 16 位 · Adobe RGB"), format: .tiff16, colorSpace: .adobeRGB, quality: 1),
    ]

    func matches(_ o: ExportOptions) -> Bool {
        o.format == format && o.colorSpace == colorSpace && (!format.usesQuality || abs(o.quality - quality) < 0.005)
    }

    func apply(to o: inout ExportOptions) {
        o.format = format; o.colorSpace = colorSpace
        if format.usesQuality { o.quality = quality }
    }
}

enum ExportColorSpace: String, CaseIterable, Identifiable, Codable, Sendable {
    case sRGB
    case displayP3
    case adobeRGB
    case proPhoto

    var id: String { rawValue }

    /// 18 % grey encoded in this space: Layer 2's tone pivot.
    var midGrey: Float {
        switch self {
        case .sRGB, .displayP3: Layer2Uniforms.srgbMidGrey
        case .adobeRGB: 0.4587           // 0.18^(1/2.2)
        case .proPhoto: Layer2Uniforms.proPhotoMidGrey
        }
    }

    var title: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "P3"
        case .adobeRGB: "Adobe RGB"
        case .proPhoto: "ProPhoto"
        }
    }

    var detail: String {
        switch self {
        case .sRGB: String(localized: "网页与社交平台的通用标准：发给别人、发到网上、在 Windows 电脑上看时最稳妥")
        case .displayP3: String(localized: "推荐 · iPhone 和 Mac 屏幕的色域，和编辑时看到的一样；比 sRGB 更鲜艳的颜色不会被裁掉")
        case .adobeRGB: String(localized: "印刷常用，青绿色域更宽")
        case .proPhoto: String(localized: "最大色域，建议只配合 TIFF 16 位使用，8 位 JPEG 容易出现色带")
        }
    }

    /// The name the engine's colour tables use.
    var engineName: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .adobeRGB: "Adobe RGB (1998)"
        case .proPhoto: "ProPhoto RGB"
        }
    }

    /// The Core Graphics space with the same primaries and transfer function
    /// the engine encodes with. ROMM RGB is ProPhoto with its 1.8 curve.
    var cgColorSpace: CGColorSpace? {
        switch self {
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)
        case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)
        case .proPhoto: CGColorSpace(name: CGColorSpace.rommrgb)
        }
    }
}

enum ExportDestination: String, CaseIterable, Identifiable, Codable, Sendable {
    case photos
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: String(localized: "相册")
        case .files: String(localized: "文件 / 分享")
        }
    }
}

struct ExportOptions: Codable, Equatable, Sendable {
    var format: ExportFormat = .heif         // the recommended preset (`ExportPreset` 日常)
    var colorSpace: ExportColorSpace = .displayP3
    /// 0.7 ... 1.0. Ignored for TIFF.
    var quality: Double = 0.9
    var destination: ExportDestination = .photos
    /// Copy the camera's EXIF, GPS and make/model from the original file.
    var keepMetadata: Bool = true

    private static let defaultsKey = "SpektraLab.exportOptions"

    static func load() -> ExportOptions {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let options = try? JSONDecoder().decode(ExportOptions.self, from: data) else {
            return ExportOptions()
        }
        return options
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// A finished export waiting for the share sheet.
struct ExportedFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
}

/// What the export sheet shows before anything is rendered at full size.
struct ExportEstimate: Equatable, Sendable {
    let width: Int
    let height: Int
    let options: ExportOptions
    /// Bytes extrapolated from the preview, before calibration.
    var rawBytes: Int64?
    /// The calibrated figure shown to the user.
    var bytes: Int64?
    /// True once a real export of this format has corrected the estimate.
    var calibrated = false

    var megapixels: Double { Double(width * height) / 1_000_000 }
}

/// Per-format correction learned from real exports. The preview is a
/// downscale, so it carries more detail per pixel than the full-size print and
/// overstates the file; the first real export measures by how much.
enum ExportCalibration {
    private static let key = "SpektraLab.exportCalibration"

    static func factor(for format: ExportFormat) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[format.rawValue]
    }

    static func record(actual: Int64, raw: Int64, format: ExportFormat) {
        guard actual > 0, raw > 0 else { return }
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let measured = Double(actual) / Double(raw)
        // A running mean, so one unusual photo does not swing it.
        if let old = all[format.rawValue] {
            all[format.rawValue] = old * 0.6 + measured * 0.4
        } else {
            all[format.rawValue] = measured
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}
