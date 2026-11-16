//  MainTabs.swift — the app's three places, in a tab bar: 底片 (the library), 拍摄 (the camera, full screen over
//  everything), 观片台. 配方与胶片 lives in Settings (rarely visited; the camera's roll grid has the recipes too). Replaces the buttons that were spread over the library's header (2026-11-16).

import SwiftUI

struct MainTabs: View {
    @EnvironmentObject private var model: ViewModel
    enum Place: Hashable { case library, camera, table }
    @State private var place: Place = .library
    @State private var shooting = false

    var body: some View {
        // 拍摄 is not a page: selecting it opens the camera, and closing the camera lands on 底片. Refusing the
        // selection in the binding left the tab bar showing the empty 拍摄 page behind the camera.
        TabView(selection: $place) {
            Tab("底片", systemImage: "photo.stack", value: Place.library) { PhotoLibraryView() }
            Tab("拍摄", systemImage: "camera.aperture", value: Place.camera) { Color.labInk }
            Tab("观片台", systemImage: "light.panel", value: Place.table) { LightTablePane(model: model, embedded: true) }
        }
        .tint(Color.labRed)
        .onChange(of: place) { _, p in if p == .camera { shooting = true } }
        // 底片 is put back under the camera the moment it starts to close (onDismiss came after the slide-down, so the
        // empty 拍摄 page showed for a beat).
        .fullScreenCover(isPresented: $shooting) { CameraView(model: model) }
        .onChange(of: shooting) { _, on in if !on { place = .library } }
        .onAppear { if model.cameraRequested { model.cameraRequested = false; shooting = true } }
        .onChange(of: model.cameraRequested) { _, wanted in
            if wanted { model.cameraRequested = false; shooting = true }
        }
    }
}
