//  HandOver.swift — pictures that reached the app while it was not running: shared from Photos / other apps (the
//  share extension's Inbox in the app group) and shot from the Lock Screen (the capture extension's session folders).
//  Taken in each time the app comes forward.

import Foundation
import LockedCameraCapture

extension ViewModel {
    /// "group." + this app's bundle id; the share extension (id + ".share") works out the same name.
    static var appGroupID: String { "group." + (Bundle.main.bundleIdentifier ?? "") }

    func collectHandedOver() async {
        guard !handingOver else { return }
        handingOver = true
        defer { handingOver = false }
        guard !exporting, !batchExporting else { return }
        let fm = FileManager.default
        if let root = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
            let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            let files = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
            if !files.isEmpty {
                NSLog("SpektraLab handover: %d shared file(s)", files.count)
                await importFiles(from: files, again: true)
                for f in files { try? fm.removeItem(at: f) }
            }
        }
        // Lock Screen shots (from the set-aside Lock Screen camera; none are written now): developed with the roll
        // loaded in the camera, like a shot taken in the app.
        let roll = UserDefaults.standard.string(forKey: "SpektraLab.cameraRoll") ?? StockCatalog.defaultFilm
        let develop = true       // every shot is developed in the app, in the background (nothing goes to Photos)
        for folder in LockedCameraCaptureManager.shared.sessionContentURLs {
            let shots = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["heic", "jpg", "jpeg", "dng"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            NSLog("SpektraLab handover: %d Lock Screen shot(s)", shots.count)
            for url in shots {
                guard let data = try? Data(contentsOf: url) else { continue }
                let isRAW = url.pathExtension.lowercased() == "dng"
                if roll.isEmpty {
                    _ = await addShotToPhotos(data, isRAW: isRAW)
                } else {
                    _ = await addCapturedShot(data, isRAW: isRAW, look: rollRecipe(roll) ?? .standard, develop: develop)
                }
            }
            try? await LockedCameraCaptureManager.shared.invalidateSessionContent(at: folder)
        }
    }

    /// The Camera Control button / control ran `SpektraCaptureIntent` with the phone unlocked: show the camera.
    func takeCameraRequestFromIntent() {
        let at = UserDefaults.standard.double(forKey: SpektraCaptureIntent.openCameraKey)
        guard at > 0, Date().timeIntervalSince1970 - at < 15 else { return }
        UserDefaults.standard.removeObject(forKey: SpektraCaptureIntent.openCameraKey)
        if editingPhotoID != nil { closeEditor() }
        cameraRequested = true
    }
}
