//  Layer2Shims.swift — the two helpers the upstream Layer 2 files expect.

import Foundation

/// Upstream's localisation call; this fork shows Chinese only.
func L(_ key: String) -> String { layer2Chinese[key] ?? key }

private let layer2Chinese: [String: String] = [
    "Exposure": "曝光", "Contrast": "对比度", "Brightness": "亮度", "Highlights": "高光",
    "Shadows": "阴影", "Whites": "白色", "Blacks": "黑色", "Vignette": "暗角", "Midpoint": "中点",
    "Temperature": "色温", "Tint": "色调", "Saturation": "饱和度", "Vibrance": "自然饱和度",
    "Red": "红", "Orange": "橙", "Yellow": "黄", "Green": "绿", "Aqua": "青", "Blue": "蓝",
    "Purple": "紫", "Magenta": "洋红", "Hue": "色相", "Luminance": "明度",
    "Master": "全局", "Midtones": "中间调", "Lights": "亮部", "Darks": "暗部",
    "Luma": "亮度", "Light": "光线", "Curve": "曲线", "Colour": "色彩", "Channels": "通道",
    "None": "无",
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
