//  MainTabs.swift — the app's three places, in a tab bar: 底片 (the library), 拍摄 (the camera, full screen over
//  everything), 观片台. 配方与胶片 lives in Settings (rarely visited; the camera's roll grid has the recipes too). Replaces the buttons that were spread over the library's header (2026-11-16).

import LockedCameraCapture
import SwiftUI

struct MainTabs: View {
    @EnvironmentObject private var model: ViewModel
    enum Place: Hashable { case library, camera, table }
    @State private var place: Place = .library
    @State private var shooting = false
    /// Each page's entrance (0 → 1) when it is chosen, and the side it comes from.
    @State private var entrance: [Place: Double] = [.library: 1, .table: 1]
    @State private var fromRight = true
    /// The camera's own fade-in, a beat after its black ground is up.
    @State private var cameraIn = false

    private static let order: [Place] = [.library, .camera, .table]

    /// A page coming in: slides 30 pt from the side it lies on in the tab bar, and fades in.
    private func entering<V: View>(_ p: Place, _ v: V) -> some View {
        let t = entrance[p] ?? 1
        return v.opacity(0.4 + 0.6 * t).offset(x: (1 - t) * (fromRight ? 30 : -30))
    }

    private func openCamera() {
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still) { cameraIn = false; shooting = true }
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.3)) { cameraIn = true } }
    }

    private func closeCamera() {
        withAnimation(.easeOut(duration: 0.25)) { shooting = false }
        place = .library
    }

    var body: some View {
        ZStack {
            TabView(selection: $place) {
                Tab("底片", systemImage: "photo.stack", value: Place.library) { entering(.library, PhotoLibraryView()) }
                Tab("拍摄", systemImage: "camera.aperture", value: Place.camera) { Color.black.ignoresSafeArea() }   // the camera's own ground, if a frame of it shows
                Tab("观片台", systemImage: "light.panel", value: Place.table) {
                    entering(.table, LightTablePane(model: model, embedded: true))
                }
            }
            .tint(Color.labRed)
            // Under the light table's big lens: the tab bar under black, the page's layout untouched.
            .overlay(alignment: .bottom) {
                if model.lightTableImmersive {
                    Color.black.frame(height: 100).ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.lightTableImmersive)
            // 拍摄 is not a page: it opens the camera over everything, and the tab underneath goes back to where it
            // was at once, so closing the camera fades back to it (no blank 拍摄 page, no slide up and down).
            .onChange(of: place) { old, new in
                if new == .camera {
                    openCamera()
                    DispatchQueue.main.async { place = old == .camera ? .library : old }
                    return
                }
                guard old != .camera, old != new else { return }
                fromRight = (Self.order.firstIndex(of: new) ?? 0) > (Self.order.firstIndex(of: old) ?? 0)
                var still = Transaction(); still.disablesAnimations = true
                withTransaction(still) { entrance[new] = 0 }
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.25)) { entrance[new] = 1 } }
            }

            if shooting {
                // A black ground that is there at once (the tab bar's empty 拍摄 page flashed through a fading-in camera),
                // the camera fading in over it from a little larger, as the Camera app opens. Closing fades it all and
                // lands on 底片, as it always has (the last shot's thumbnail means "show me the library").
                ZStack {
                    Color.black.ignoresSafeArea()
                    CameraView(model: model, close: closeCamera)
                        .opacity(cameraIn ? 1 : 0)
                        .scaleEffect(cameraIn ? 1 : 1.05)
                }
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
                .zIndex(1)
            }
        }
        .onAppear { if model.cameraRequested { model.cameraRequested = false; openCamera() } }
        // The camera configured in the background at launch, so the first 拍摄 only has to start it.
        .task {
            let d = UserDefaults.standard
            let format = CameraController.Format(rawValue: d.string(forKey: "SpektraLab.cameraFormat") ?? "") ?? .proRAW
            let mp = d.object(forKey: "SpektraLab.cameraSizeMP") as? Int ?? 48
            CameraController.shared.prepare(format: format, mp: mp)
        }
        // Camera Control pressed while locked: the capture extension asked to unlock and handed over — the camera.
        .onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { _ in
            if model.editingPhotoID != nil { model.closeEditor() }
            openCamera()
        }
        // The Camera Control button while the app is already open.
        .onReceive(NotificationCenter.default.publisher(for: SpektraCaptureIntent.openCamera)) { _ in
            model.takeCameraRequestFromIntent()
        }
        .onChange(of: model.cameraRequested) { _, wanted in
            if wanted { model.cameraRequested = false; openCamera() }
        }
    }
}
