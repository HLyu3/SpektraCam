//  CaptureExtension.swift — what the Camera Control button opens while the phone is locked: it asks to unlock and
//  opens Spektra Cam's own camera, as most camera apps do. iOS lists an app under Settings › Camera › Camera Control
//  only if it has a capture extension, so this one exists to hand over.
//  A real Lock Screen camera (its own viewfinder, flash, front camera, sizes, shots collected by the app) was built
//  and set aside (commit 92e7df7): a locked extension cannot run the film engine or read the library, so it could
//  only be a lighter camera; for later.

import ExtensionKit
import LockedCameraCapture
import SwiftUI

@main
struct SpektraCaptureExtension: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            UnlockToShoot(session: session)
        }
    }
}

struct UnlockToShoot: View {
    let session: LockedCameraCaptureSession
    private let cream = Color(red: 0.95, green: 0.91, blue: 0.84)
    private let amber = Color(red: 0.93, green: 0.62, blue: 0.24)

    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.10, blue: 0.09).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(amber)
                Text("Spektra Cam").font(.title2.weight(.semibold)).foregroundStyle(cream)
                Text("解锁后打开相机").font(.subheadline).foregroundStyle(cream.opacity(0.6))
                Button(action: open) {
                    Text("解锁")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 34)
                        .frame(height: 46)
                        .background(amber, in: Capsule())
                }
                .padding(.top, 10)
            }
        }
        .task { open() }               // straight to the unlock prompt; the button is for after a cancel
    }

    private func open() {
        Task { try? await session.openApplication(for: NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)) }
    }
}
