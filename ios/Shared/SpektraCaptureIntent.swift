//  SpektraCaptureIntent.swift — the action behind the Camera Control button and the Lock Screen / Control Center
//  control. Compiled into the app, the control extension and the capture extension (the system needs it in all
//  three). Locked, the system opens the capture extension; unlocked, the app, which shows its camera.

import AppIntents
import Foundation

struct SpektraCaptureIntent: CameraCaptureIntent {
    /// Nothing is passed to the capture extension.
    struct AppContext: Codable, Sendable {}

    static let title: LocalizedStringResource = "Spektra Cam 拍摄"
    static let description = IntentDescription("打开 Spektra Cam 的胶片相机。")

    @MainActor
    func perform() async throws -> some IntentResult {
        // Read by the app as it comes forward (`ViewModel.sceneBecameActive`).
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SpektraCaptureIntent.openCameraKey)
        NotificationCenter.default.post(name: SpektraCaptureIntent.openCamera, object: nil)
        return .result()
    }

    static let openCameraKey = "SpektraLab.openCameraAt"
    static let openCamera = Notification.Name("SpektraLab.openCamera")
}
