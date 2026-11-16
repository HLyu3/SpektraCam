//  SpektraControl.swift — the control the Camera Control button (Settings › Camera › Camera Control), the Lock Screen
//  and Control Center offer: it runs `SpektraCaptureIntent`.

import AppIntents
import SwiftUI
import WidgetKit

@main
struct SpektraControls: WidgetBundle {
    var body: some Widget { SpektraCameraControl() }
}

struct SpektraCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SpektraLab.camera") {
            ControlWidgetButton(action: SpektraCaptureIntent()) {
                Label("Spektra Cam", systemImage: "camera.aperture")
            }
        }
        .displayName("Spektra Cam 拍摄")
        .description("打开 Spektra Cam 的胶片相机。")
    }
}
