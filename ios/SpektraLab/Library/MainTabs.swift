//  MainTabs.swift — the app's three places: 底片 (the library, home), 拍摄 (the camera, rising from the bottom),
//  观片台 (pushed in from the right). No tab bar since 2026-11-17. 配方与胶片 lives in Settings (rarely visited; the camera's roll grid has the recipes too). Replaces the buttons that were spread over the library's header (2026-11-16).

import LockedCameraCapture
import SwiftUI

struct MainTabs: View {
    @EnvironmentObject private var model: ViewModel
    enum Place: Hashable { case library, camera, table }
    /// 底片 is home. The camera rises over it from the bottom (the floating shutter button) and sinks back; the
    /// light table is pushed in from the right (the header's button) and goes back the same way. 2026-11-17: a tab
    /// bar with the pages in a row slid 底片 → 观片台 across a black camera page — the owner wanted no tab bar.
    @State private var place: Place = .library
    /// The page that is live (camera running, table open). It changes a beat BEFORE `place` moves, so starting a page
    /// is not done in the frames of its slide.
    @State private var live: Place = .library
    /// The camera and the light table are built once, a moment after launch, and then only moved: building them as
    /// they slid in made the slide stutter. Off screen they are idle (`active` false: camera stopped, viewfinder
    /// paused; the table's background develops stopped, the table itself closed after 30 s).
    @State private var mounted: Set<Place> = [.library]

    private func go(_ next: Place) {
        guard next != place else { return }
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still) { mounted.insert(next); live = next }
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.42, bounce: 0)) { place = next }
        }
    }

    private func openCamera() { go(.camera) }
    private func closeCamera() { go(.library) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            ZStack {
                LabBackdrop().ignoresSafeArea()
                PhotoLibraryView()
                    // Under a pushed page, as in a navigation stack: a third of the way left, dimmed.
                    .offset(x: place == .table ? -w * 0.3 : 0)
                    .overlay { Color.black.opacity(place == .table ? 0.35 : 0).ignoresSafeArea().allowsHitTesting(false) }
                    .allowsHitTesting(place == .library)
                if mounted.contains(.table) {
                    LightTablePane(model: model, close: { go(.library) }, active: live == .table)
                        .background(LabBackdrop().ignoresSafeArea())
                        .offset(x: place == .table ? 0 : w)
                        .allowsHitTesting(place == .table)
                        .zIndex(1)
                }
                if mounted.contains(.camera) {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        CameraView(model: model, close: closeCamera, active: live == .camera)
                    }
                    .offset(y: place == .camera ? 0 : h)
                    .allowsHitTesting(place == .camera)
                    .zIndex(2)
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            mounted.formUnion([.camera, .table])
        }
        .onChange(of: model.lightTableRequested) { _, wanted in
            if wanted { model.lightTableRequested = false; go(.table) }
        }
        .onAppear { if model.cameraRequested { model.cameraRequested = false; openCamera() } }
        // The camera configured in the background at launch, so the first 拍摄 only has to start it.
        .task {
            let d = UserDefaults.standard
            let format = CameraController.Format(rawValue: d.string(forKey: "SpektraLab.cameraFormat") ?? "") ?? .proRAW
            let mp = d.object(forKey: "SpektraLab.cameraSizeMP") as? Int ?? 12
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
