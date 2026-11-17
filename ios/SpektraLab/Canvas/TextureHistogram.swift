//  TextureHistogram.swift — the editor's histogram: the picture on the canvas counted on the GPU
//  (MPSImageHistogram, 64 bins a channel over 0…1 of its encoded values), so it follows every render at no cost to a
//  slider's drag. Only the counts come back.

import Metal
import MetalPerformanceShaders

enum TextureHistogram {
    static let bins = 64

    /// Red, green and blue, each `bins` long, scaled so the tallest bin of the three is 1. Nil if the texture's
    /// format cannot be counted.
    /// On the main actor, as the canvas's texture is: the work itself is the GPU's, the wait is a completion handler.
    @MainActor
    static func compute(_ texture: MTLTexture, queue: MTLCommandQueue) async -> [[Float]]? {
        let device = queue.device
        var info = MPSImageHistogramInfo(numberOfHistogramEntries: bins, histogramForAlpha: false,
                                         minPixelValue: vector_float4(0, 0, 0, 0),
                                         maxPixelValue: vector_float4(1, 1, 1, 1))
        let histogram = MPSImageHistogram(device: device, histogramInfo: &info)
        let size = histogram.histogramSize(forSourceFormat: texture.pixelFormat)
        guard size > 0, let buffer = device.makeBuffer(length: size, options: .storageModeShared),
              let commands = queue.makeCommandBuffer() else { return nil }
        histogram.encode(to: commands, sourceTexture: texture, histogram: buffer, histogramOffset: 0)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            commands.addCompletedHandler { _ in done.resume() }
            commands.commit()
        }
        let counts = buffer.contents().bindMemory(to: UInt32.self, capacity: bins * 4)
        var channels = (0..<3).map { c in (0..<bins).map { Float(counts[c * bins + $0]) } }
        // The ends hold the clipped pixels and dwarf the rest: scaled by the tallest inner bin, ends capped at 1.
        let top = channels.flatMap { $0.dropFirst().dropLast() }.max() ?? 1
        guard top > 0 else { return nil }
        channels = channels.map { $0.map { min($0 / top, 1) } }
        return channels
    }
}
