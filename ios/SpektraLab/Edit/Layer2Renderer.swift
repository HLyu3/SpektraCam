//  Layer2Renderer.swift — Layer 2 run on a picture (preview or export).
//
//  Ported from upstream `app/SpektraLab/Sources/Engine/Layer2Renderer.swift`
//  (GPL-3). Trimmed for iOS: no 成片 local layers, histogram or buffer pool,
//  and the colour space is a parameter (upstream is fixed to Display P3) so the
//  preview runs in sRGB and an export in its own space without clipping.
//
//      a CGImage ──draw──▶ RGBA16 in `space`, shared buffer   (`source`)
//                └─ spkLayer2 ─▶ RGBA16, shared buffer ──▶ a CGImage / a texture

import CoreGraphics
import Foundation
import Metal

/// A picture as the pass reads it: RGBA, 16 bits a channel, tightly packed.
final class Layer2Source: @unchecked Sendable {
    let buffer: MTLBuffer
    let width: Int
    let height: Int
    var bytes: Int { width * height * 8 }
    init(buffer: MTLBuffer, width: Int, height: Int) {
        self.buffer = buffer; self.width = width; self.height = height
    }
}

final class Layer2Renderer: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case memory(String), gpu(String), picture(String)
        var description: String {
            switch self {
            case .memory(let s), .gpu(let s), .picture(let s): s
            }
        }
    }

    static let shared: Layer2Renderer? = try? Layer2Renderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pass: MTLComputePipelineState
    private let identityCurves: MTLBuffer

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw Layer2Kernel.Failure.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.gpu("no command queue for Layer 2") }
        self.queue = queue
        let library = try Layer2Kernel.library(device)
        guard let f = library.makeFunction(name: "spkLayer2") else { throw Layer2Kernel.Failure.compile("spkLayer2 is missing") }
        pass = try device.makeComputePipelineState(function: f)
        let identity = CurveSet().tables()
        guard let curves = device.makeBuffer(bytes: identity, length: identity.count * 4, options: .storageModeShared) else {
            throw Failure.memory("no buffer for the curve table")
        }
        identityCurves = curves
    }

    /// The preview's space: Display P3, the engine's preview output (`ParamDefaults`) and the canvas's.
    static let previewSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    // MARK: the picture in

    /// `image`, drawn into a source in `space`, 16 bits a channel.
    func source(_ image: CGImage, space: CGColorSpace = Layer2Renderer.previewSpace) throws -> Layer2Source {
        let (w, h) = (image.width, image.height)
        let buffer = try makeBuffer(width: w, height: h)
        guard let context = Self.context(buffer.contents(), width: w, height: h, space: space) else {
            throw Failure.picture("the picture could not be drawn for Layer 2")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Layer2Source(buffer: buffer, width: w, height: h)
    }

    func makeBuffer(width: Int, height: Int) throws -> MTLBuffer {
        let bytes = width * height * 8
        guard bytes > 0, bytes <= device.maxBufferLength,
              let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw Failure.memory("no \(bytes >> 20) MB buffer for a picture of \(width) x \(height)")
        }
        return buffer
    }

    /// RGBA, 16 bits a channel little-endian, the fourth unused — the kernels' layout.
    private static func context(_ data: UnsafeMutableRawPointer, width: Int, height: Int, space: CGColorSpace) -> CGContext? {
        for alpha in [CGImageAlphaInfo.noneSkipLast, .premultipliedLast] {
            let info = CGBitmapInfo.byteOrder16Little.rawValue | alpha.rawValue
            if let c = CGContext(data: data, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                                 space: space, bitmapInfo: info) { return c }
        }
        return nil
    }

    // MARK: the pass

    private struct Size { var width: UInt32; var height: UInt32; var stride: UInt32; var applies: UInt32 }

    /// The pass into `out`. `midGrey` is 18 % grey encoded in the picture's space.
    func apply(_ source: Layer2Source, _ a: Adjustments, midGrey: Float = Layer2Uniforms.displayMidGrey,
               into out: MTLBuffer) throws {
        let curves: MTLBuffer? = a.curves.isIdentity ? identityCurves : {
            let t = a.curves.tables()
            return device.makeBuffer(bytes: t, length: t.count * 4, options: .storageModeShared)
        }()
        guard out.length >= source.bytes, let curves,
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw Failure.gpu("the Layer 2 pass could not be encoded")
        }
        var u = a.uniforms(midGrey: midGrey)
        var size = Size(width: UInt32(source.width), height: UInt32(source.height), stride: 1, applies: 1)
        encoder.setComputePipelineState(pass)
        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBuffer(out, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 2)
        encoder.setBuffer(curves, offset: 0, index: 3)
        encoder.setBytes(&size, length: MemoryLayout<Size>.stride, index: 4)
        let tw = pass.threadExecutionWidth, th = max(1, pass.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (source.width + tw - 1) / tw, height: (source.height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw Failure.gpu("the Layer 2 pass failed: \(error.localizedDescription)") }
    }

    /// The pass, out as a `.rgba16Unorm` texture for the canvas (already sRGB-encoded).
    func texture(_ source: Layer2Source, _ a: Adjustments) throws -> MTLTexture {
        let out = try makeBuffer(width: source.width, height: source.height)
        try apply(source, a, into: out)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: source.width,
                                                         height: source.height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { throw Failure.memory("no texture for the adjusted preview") }
        t.replace(region: MTLRegionMake2D(0, 0, source.width, source.height), mipmapLevel: 0,
                  withBytes: out.contents(), bytesPerRow: source.width * 8)
        return t
    }

    /// The pass, out as a `CGImage` in `space` over the buffer the kernel wrote.
    func image(_ source: Layer2Source, _ a: Adjustments, space: CGColorSpace,
               midGrey: Float = Layer2Uniforms.displayMidGrey) throws -> CGImage {
        let out = try makeBuffer(width: source.width, height: source.height)
        try apply(source, a, midGrey: midGrey, into: out)
        return try Self.image(of: Layer2Source(buffer: out, width: source.width, height: source.height), space: space)
    }

    /// A `CGImage` over the source's own buffer (no copy), holding the buffer while it lives.
    static func image(of source: Layer2Source, space: CGColorSpace) throws -> CGImage {
        let out = source.buffer
        let held = Unmanaged.passRetained(out as AnyObject)
        guard let provider = CGDataProvider(dataInfo: held.toOpaque(), data: out.contents(), size: source.bytes,
                                            releaseData: { info, _, _ in
                                                if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
                                            }) else {
            held.release()
            throw Failure.picture("no data provider for the adjusted picture")
        }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let image = CGImage(width: source.width, height: source.height, bitsPerComponent: 16, bitsPerPixel: 64,
                                  bytesPerRow: source.width * 8, space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw Failure.picture("the adjusted picture could not be made")
        }
        return image
    }
}
