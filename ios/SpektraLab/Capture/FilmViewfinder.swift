//  FilmViewfinder.swift — the camera's live frames through the roll's colour cube, on the GPU.
//  Colour and tone of the film on its paper; no grain or halation (those are developed after).

import CoreImage
import MetalKit
import SwiftUI

/// Holds the newest frame and the cube; the video queue writes, the display link reads.
final class FilmViewfinderRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    /// One for the app's life: its Core Image context and the cube's GPU program are made once, not on every visit
    /// to the camera (that, with the black view below, was the pause on opening it).
    static let shared = FilmViewfinderRenderer()

    private let lock = NSLock()
    private var frame: CIImage?
    private var cube: CIFilter?
    let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var context: CIContext? = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }

    func push(_ pixels: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixels)
        lock.lock(); frame = image; lock.unlock()
    }

    func setCube(_ data: Data?, size: Int) {
        var filter: CIFilter?
        if let data, let f = CIFilter(name: "CIColorCubeWithColorSpace") {
            f.setValue(size, forKey: "inputCubeDimension")
            f.setValue(data, forKey: "inputCubeData")
            f.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
            filter = f
        }
        lock.lock(); cube = filter; lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock(); let image = frame; let cube = cube; lock.unlock()
        guard let image, let cube, let context, let queue,
              let drawable = view.currentDrawable, let commands = queue.makeCommandBuffer() else { return }
        // Fill the view (as the preview layer's resizeAspectFill does), then the film's colours.
        let target = CGSize(width: view.drawableSize.width, height: view.drawableSize.height)
        let k = max(target.width / image.extent.width, target.height / image.extent.height)
        var scaled = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        scaled = scaled.transformed(by: CGAffineTransform(translationX: (target.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                          y: (target.height - scaled.extent.height) / 2 - scaled.extent.minY))
        cube.setValue(scaled, forKey: kCIInputImageKey)
        guard let out = cube.outputImage else { return }
        context.render(out, to: drawable.texture, commandBuffer: commands,
                       bounds: CGRect(origin: .zero, size: target), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        commands.present(drawable)
        commands.commit()
    }
}

struct FilmViewfinder: UIViewRepresentable {
    let renderer: FilmViewfinderRenderer
    /// Off screen (the camera page kept a moment after it is left) it must not draw: an unseen Metal layer never
    /// gives its drawables back, and every draw then waited on the main thread for one — the app froze for seconds.
    var active = true

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.framebufferOnly = false          // Core Image writes into the drawable's texture
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.delegate = renderer
        view.isUserInteractionEnabled = false
        // See-through until it has drawn: the live preview under it shows (plain colours) instead of black while the
        // film's cube is made.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) { view.isPaused = !active }
}
