//  Layer2Shims.swift — the two helpers the upstream Layer 2 files expect.

import Foundation

/// Upstream's localisation call; this fork shows Chinese only.
func L(_ key: String) -> String { layer2Chinese[key] ?? key }

private let layer2Chinese: [String: String] = [
    "Exposure": String(localized: "曝光"), "Contrast": String(localized: "对比度"), "Brightness": String(localized: "亮度"), "Highlights": String(localized: "高光"),
    "Shadows": String(localized: "阴影"), "Whites": String(localized: "白色"), "Blacks": String(localized: "黑色"), "Vignette": String(localized: "暗角"), "Midpoint": String(localized: "中点"),
    "Temperature": String(localized: "色温"), "Tint": String(localized: "色调"), "Saturation": String(localized: "饱和度"), "Vibrance": String(localized: "自然饱和度"),
    "Red": String(localized: "红"), "Orange": String(localized: "橙"), "Yellow": String(localized: "黄"), "Green": String(localized: "绿"), "Aqua": String(localized: "青"), "Blue": String(localized: "蓝"),
    "Purple": String(localized: "紫"), "Magenta": String(localized: "洋红"), "Hue": String(localized: "色相"), "Luminance": String(localized: "明度"),
    "Master": String(localized: "全局"), "Midtones": String(localized: "中间调"), "Lights": String(localized: "亮部"), "Darks": String(localized: "暗部"),
    "Luma": String(localized: "亮度"), "Light": String(localized: "光线"), "Curve": String(localized: "曲线"), "Colour": String(localized: "色彩"), "Channels": String(localized: "通道"),
    "None": String(localized: "无"),
]

/// From upstream `Sources/Model/Format.swift`.
enum Fmt {
    /// "+0.3", "−1.25", "0.00" at 0 when `plusAtZero` is false.
    static func signed(_ v: Double, decimals: Int = 1, plusAtZero: Bool = false) -> String {
        let body = String(format: "%.\(decimals)f", abs(v))
        let zero = Double(body) == 0
        if zero { return plusAtZero ? "±" + body : body }
        return (v < 0 ? "−" : "+") + body
    }
}

/// A text known only at run time (an enum's raw value: 取景, 快门…) looked up in Localizable.xcstrings; the
/// literals elsewhere go through `String(localized:)`, which the catalog extraction sees.
func tr(_ key: String) -> String { NSLocalizedString(key, comment: "") }
