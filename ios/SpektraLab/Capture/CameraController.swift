//  CameraController.swift — the cameras, shooting Apple ProRAW or HEIF, with manual exposure,
//  white balance, focus, a live histogram and readouts.
//
//  AVFoundation is touched on one serial queue (`queue`); what the page shows is published on
//  the main actor by `CameraModel`.

import AVFoundation
import CoreMotion
import UIKit

final class CameraController: NSObject, @unchecked Sendable {
    enum Format: String, CaseIterable, Identifiable {
        /// Apple ProRAW: multi-frame, denoised, partly sharpened, linear DNG.
        /// RAW: one frame of the sensor (Bayer DNG) — no fusion, denoise or sharpening.
        case proRAW, raw, heif
        var id: String { rawValue }
        var title: String {
            switch self {
            case .proRAW: "ProRAW"
            case .raw: "RAW"
            case .heif: "HEIF"
            }
        }
    }

    enum Flash: String, CaseIterable { case off, auto, on }

    struct Shot: @unchecked Sendable {
        let data: Data
        let isRAW: Bool
        /// The lens's digital zoom when shot, and the long edge asked for: a RAW the zoom did not
        /// crop comes back at that size, and the library crops it instead (`addCapturedShot`).
        var zoom: Double = 1
        var askedLongEdge = 0
    }

    /// A camera module, named by its 35 mm-equivalent focal length.
    struct Lens: Identifiable, Hashable, @unchecked Sendable {
        let device: AVCaptureDevice
        let millimetres: Int
        var id: String { device.uniqueID }
    }

    /// What the page shows, read on the queue and handed to the main actor.
    struct Status: Sendable, Equatable {
        var shutter: Double = 0          // seconds
        var iso: Float = 0
        var bias: Float = 0
        var manual = false
        var temperature: Float = 5500
        var wbLocked = false
        var minISO: Float = 50, maxISO: Float = 3200
        var minShutter: Double = 1.0 / 8000, maxShutter: Double = 1.0 / 3
        var minBias: Float = -4, maxBias: Float = 4
        var proRAW = false               // the lens offers Apple ProRAW
        var bayer = false                // the lens offers single-frame Bayer RAW
        var flash = false
        var megapixels = 0
        /// The sizes this lens can shoot, in MP as Apple names them (12, 24, 48).
        var sizes: [Int] = []
    }

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let video = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "SpektraLab.camera")
    private let videoQueue = DispatchQueue(label: "SpektraLab.camera.video")
    private var input: AVCaptureDeviceInput?
    private var inFlight: [Int64: PhotoDelegate] = [:]
    private var frameCount = 0
    /// Called (on the video queue) with 64 luminance bins, about five times a second.
    var onHistogram: (([Float]) -> Void)?
    /// Every video frame, upright (on the video queue): the film viewfinder draws from it.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// The size to shoot, in MP as named (12, 24, 48); 0 or a size the lens lacks takes its largest.
    var preferredMP = 0

    private(set) var lenses: [Lens] = []
    private(set) var frontLens: Lens?

    /// The lenses, named as Apple names them (13, 24, 100 mm on an iPhone 17 Pro). The field of
    /// view alone lands a few mm off (96 or 104 for the 100), so each is snapped to Apple's figure.
    static func lenses(position: AVCaptureDevice.Position) -> [Lens] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices
        func halfFOV(_ d: AVCaptureDevice) -> Double { max(Double(d.activeFormat.videoFieldOfView) * .pi / 360, 0.01) }
        let wide = found.first { $0.deviceType == .builtInWideAngleCamera }
        // The main camera is 24 mm since the 48 MP sensor (iPhone 15), 26 mm before it.
        // Any of its formats, not the active one: before the session is set up the active format is
        // a 16:9 video one with no 48 MP still (logged on an iPhone 17 Pro Max), which read as 26 mm.
        let wideMM = wide.map { w in
            w.formats.contains { $0.supportedMaxPhotoDimensions.contains { megapixels($0) >= 40 } } ? 24.0 : 26.0
        } ?? 24
        return found.map { d -> Lens in
            switch d.deviceType {
            case .builtInUltraWideCamera:
                return Lens(device: d, millimetres: 13)
            case .builtInTelephotoCamera:
                // The telephoto against the main camera, then Apple's nearest figure.
                let estimate = wide.map { wideMM * tan(halfFOV($0)) / tan(halfFOV(d)) } ?? 18 / tan(halfFOV(d))
                let named = [48.0, 52, 65, 77, 100, 120].min { abs($0 - estimate) < abs($1 - estimate) } ?? estimate
                return Lens(device: d, millimetres: Int(named))
            default:
                return Lens(device: d, millimetres: position == .front ? Int((18 / tan(halfFOV(d))).rounded()) : Int(wideMM))
            }
        }
        .sorted { $0.millimetres < $1.millimetres }
    }

    // MARK: session

    /// One camera for the app's life: the session stays configured between visits, so reopening the camera only
    /// starts it running (configuring a 48 MP ProRAW pipeline from nothing is what made opening pause on black).
    static let shared = CameraController()

    /// Discover the lenses and configure the main camera ahead of the first visit, without starting it (nothing
    /// is captured and the camera light stays off). Only with access already granted.
    func prepare(format f: Format, mp: Int) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        preferredMP = mp
        queue.async {
            self.format = f
            guard self.input == nil else { return }
            let t0 = CACurrentMediaTime()
            self.lenses = Self.lenses(position: .back)
            self.frontLens = Self.lenses(position: .front).first
            guard let main = self.lenses.first(where: { $0.device.deviceType == .builtInWideAngleCamera }) ?? self.lenses.first
            else { return }
            _ = self.configure(main.device)
            NSLog("SpektraLab capture: prepared in %.0f ms", (CACurrentMediaTime() - t0) * 1000)
        }
    }

    /// Ask for access, configure on `lens` (or the main camera), start. Returns an error text, or nil.
    func start() async -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return "没有相机权限" }
        case .authorized: break
        default: return "没有相机权限，请在“设置 > Spektra Cam”里打开相机"
        }
        return await withCheckedContinuation { done in
            queue.async {
                if self.input == nil {
                    self.lenses = Self.lenses(position: .back)
                    self.frontLens = Self.lenses(position: .front).first
                    guard let main = self.lenses.first(where: { $0.device.deviceType == .builtInWideAngleCamera })
                            ?? self.lenses.first else {
                        done.resume(returning: "找不到后置相机"); return
                    }
                    if let problem = self.configure(main.device) { done.resume(returning: problem); return }
                }
                let t0 = CACurrentMediaTime()
                if !self.session.isRunning { self.session.startRunning() }
                NSLog("SpektraLab capture: running in %.0f ms", (CACurrentMediaTime() - t0) * 1000)
                done.resume(returning: nil)
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// `zoom` is the lens's digital zoom (1 = its own field of view), set once the lens is in.
    func use(_ device: AVCaptureDevice, zoom: Double = 1) {
        queue.async {
            // Swapping the lens under a shot still being read out fails that shot: wait for it.
            if self.input?.device != device, !self.inFlight.isEmpty { self.waitingLens = (device, zoom); return }
            self.waitingLens = nil
            if self.input?.device != device { _ = self.configure(device) }
            self.applyZoom(zoom)
        }
    }

    /// A lens asked for while a shot was in flight, put in when the last one lands.
    private var waitingLens: (AVCaptureDevice, Double)?

    /// The current lens's digital zoom, from the main actor (a pinch).
    func setZoom(_ zoom: Double) {
        queue.async {
            if self.waitingLens != nil { self.waitingLens?.1 = zoom } else { self.applyZoom(zoom) }
        }
    }

    /// Bayer RAW refuses any digital zoom (an ObjC exception), and setting 1× just before the shot
    /// caught the sensor still in its 2× read-out: the CFA shifted, the file came out purple. So under
    /// RAW the lens stays at 1× (the page offers only the lenses' own lengths there).
    private func applyZoom(_ zoom: Double) {
        let zoom = format == .raw && bayerSupported ? 1 : zoom
        guard let d = input?.device, (try? d.lockForConfiguration()) != nil else { return }
        d.videoZoomFactor = min(max(CGFloat(zoom), d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
        d.unlockForConfiguration()
    }

    private func configure(_ device: AVCaptureDevice) -> String? {
        guard let newInput = try? AVCaptureDeviceInput(device: device) else { return "相机无法启动" }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else { return "相机无法启动" }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { return "相机无法启动" }
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .quality
        }
        if !session.outputs.contains(video), session.canAddOutput(video) {
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            video.alwaysDiscardsLateVideoFrames = true
            video.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(video)
        }
        // Upright frames for the film viewfinder (the preview layer turns its own).
        if let c = video.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        if let c = video.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = device.position == .front
        }
        applySize()
        NSLog("SpektraLab capture: lens %@ in-sensor zoom at %@", device.localizedName,
              device.activeFormat.secondaryNativeResolutionZoomFactors.map { String(format: "%.1fx", $0) }.joined(separator: ", "))
        // Bayer RAW formats are listed only while ProRAW is off: look, then set what the format wants.
        output.isAppleProRAWEnabled = false
        bayerSupported = output.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        output.isAppleProRAWEnabled = format == .proRAW && output.isAppleProRAWSupported
        return nil
    }

    /// The format shots will take; ProRAW and Bayer RAW cannot both be on.
    private(set) var format: Format = .proRAW
    private var bayerSupported = false

    func setFormat(_ f: Format) {
        queue.async {
            self.format = f
            guard self.input != nil else { return }
            let wanted = f == .proRAW && self.output.isAppleProRAWSupported
            if self.output.isAppleProRAWEnabled != wanted { self.output.isAppleProRAWEnabled = wanted }
        }
    }

    /// Megapixels as Apple names a size: 8064 × 6048 is "48 MP", not 49.
    static func megapixels(_ d: CMVideoDimensions) -> Int {
        Int(Double(d.width) * Double(d.height) / 1_000_000)
    }

    private func applySize() {
        guard let device = input?.device else { return }
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
            .sorted { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        if let pick = sizes.last(where: { Self.megapixels($0) == preferredMP }) ?? sizes.last {
            output.maxPhotoDimensions = pick
        }
    }

    func setSize(_ mp: Int) {
        queue.async { self.preferredMP = mp; self.applySize() }
    }

    /// Format and size together, in one configuration: each of them rebuilds the photo pipeline
    /// on its own (ProRAW on/off most of all), and two rebuilds in a row made the switch stall.
    func setMode(_ f: Format, mp: Int) {
        queue.async {
            let t0 = CACurrentMediaTime()
            self.format = f
            self.preferredMP = mp
            guard let device = self.input?.device else { return }
            let wanted = f == .proRAW && self.output.isAppleProRAWSupported
            self.session.beginConfiguration()
            if self.output.isAppleProRAWEnabled != wanted { self.output.isAppleProRAWEnabled = wanted }
            self.applySize()
            self.session.commitConfiguration()
            // RAW holds the lens at 1× (`applyZoom`); leaving it, the zoom comes back from the page.
            if f == .raw, self.bayerSupported, device.videoZoomFactor != 1 { self.applyZoom(1) }
            NSLog("SpektraLab capture: mode %@ %d MP in %.0f ms", f.rawValue, mp, (CACurrentMediaTime() - t0) * 1000)
        }
    }

    // MARK: exposure, white balance, focus

    private func adjust(_ body: @escaping (AVCaptureDevice) -> Void) {
        queue.async {
            guard let d = self.input?.device, (try? d.lockForConfiguration()) != nil else { return }
            body(d)
            d.unlockForConfiguration()
        }
    }

    func setBias(_ ev: Float) {
        adjust { d in d.setExposureTargetBias(min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias)) }
    }

    /// Manual shutter and ISO; nil for either keeps the current value. `auto` goes back to the meter.
    func setManual(shutter: Double?, iso: Float?) {
        adjust { d in
            let f = d.activeFormat
            let s = shutter.map { min(max($0, f.minExposureDuration.seconds), f.maxExposureDuration.seconds) }
            let i = iso.map { min(max($0, f.minISO), f.maxISO) }
            d.setExposureModeCustom(duration: s.map { CMTime(seconds: $0, preferredTimescale: 1_000_000) }
                                        ?? AVCaptureDevice.currentExposureDuration,
                                    iso: i ?? AVCaptureDevice.currentISO)
        }
    }

    func setAutoExposure() {
        adjust { d in if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure } }
    }

    func setTemperature(_ kelvin: Float?) {
        adjust { d in
            guard let kelvin else {
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                return
            }
            guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            var g = d.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0))
            let m = d.maxWhiteBalanceGain
            g.redGain = min(max(g.redGain, 1), m); g.greenGain = min(max(g.greenGain, 1), m); g.blueGain = min(max(g.blueGain, 1), m)
            d.setWhiteBalanceModeLocked(with: g)
        }
    }

    /// Set once a tap or a hold moves focus off the centre; the scene's next big change takes it back
    /// (`subjectAreaDidChange`), as Camera does. A hold (AE/AF lock) is never taken back.
    private var subjectObserver: NSObjectProtocol?
    private var aeafLocked = false
    /// When the last tap focused: the lens's own travel can read as a "subject change", which pulled focus back to
    /// the centre right after the tap (a second, jerky focus). Changes this soon after a tap are ignored.
    private var tappedAt = Date.distantPast

    private func watchSubject(_ d: AVCaptureDevice) {
        d.isSubjectAreaChangeMonitoringEnabled = true
        guard subjectObserver == nil else { return }
        subjectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                                                                 object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard Date().timeIntervalSince(self.tappedAt) > 2 else { return }
                self.backToAuto()
            }
        }
    }

    /// Focus and meter on the centre again, continuously, with no exposure bias.
    private func backToAuto() {
        adjust { d in
            guard !self.aeafLocked else { return }
            let centre = CGPoint(x: 0.5, y: 0.5)
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = centre }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = centre }
            if d.exposureMode != .custom, d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            d.setExposureTargetBias(0)
            d.isSubjectAreaChangeMonitoringEnabled = false
        }
    }

    /// Focus and meter at a point in device coordinates (0…1, the sensor's landscape frame). As in Camera, a new
    /// point starts at no exposure bias, and a big change in the scene later returns to the centre.
    func focus(at point: CGPoint) {
        adjust { d in
            self.aeafLocked = false
            d.setExposureTargetBias(0)
            self.watchSubject(d)
            // One focus at the point (`.autoFocus`), as Camera and Apple's AVCam do: re-setting continuous autofocus
            // with a new point did not move the lens — only the exposure followed the tap. The subject-area change
            // (`watchSubject`) hands focus back to the continuous centre later.
            self.tappedAt = Date()
            // A slower, steadier pull to the new distance, as Camera's (meant for video; on stills it only eases the move).
            if d.isSmoothAutoFocusSupported { d.isSmoothAutoFocusEnabled = true }
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = point }
            if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
            else if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = point }
            if d.exposureMode != .custom, d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposureMode = .continuousAutoExposure
            }
            NSLog("SpektraLab camera: focus at %.2f,%.2f (focus point %@, mode %d)", point.x, point.y,
                  d.isFocusPointOfInterestSupported ? "yes" : "NO", d.focusMode.rawValue)
        }
    }

    /// AE/AF lock, as Camera's long press: focus and meter once at the point, then hold both (a tap unlocks:
    /// `focus(at:)` goes back to continuous).
    func lock(at point: CGPoint) {
        adjust { d in
            self.aeafLocked = true
            d.isSubjectAreaChangeMonitoringEnabled = false
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = point }
            if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }        // one focus, then held
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = point }
            if d.exposureMode != .custom, d.isExposureModeSupported(.autoExpose) { d.exposureMode = .autoExpose }
        }
    }

    /// The current state, for the page's readouts and controls.
    func status() async -> Status {
        await withCheckedContinuation { done in
            queue.async {
                var s = Status()
                if let d = self.input?.device {
                    let f = d.activeFormat
                    s.shutter = d.exposureDuration.seconds
                    s.iso = d.iso
                    s.bias = d.exposureTargetBias
                    s.manual = d.exposureMode == .custom
                    s.minISO = f.minISO; s.maxISO = f.maxISO
                    s.minShutter = f.minExposureDuration.seconds
                    s.maxShutter = min(f.maxExposureDuration.seconds, 1.0 / 3)
                    s.minBias = d.minExposureTargetBias; s.maxBias = d.maxExposureTargetBias
                    s.wbLocked = d.whiteBalanceMode == .locked
                    // The conversion throws (an ObjC exception, a crash) for gains outside 1…max, which a
                    // camera reports while it settles or on a lens that cannot lock custom gains.
                    if d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                        var g = d.deviceWhiteBalanceGains
                        let m = d.maxWhiteBalanceGain
                        g.redGain = min(max(g.redGain, 1), m); g.greenGain = min(max(g.greenGain, 1), m)
                        g.blueGain = min(max(g.blueGain, 1), m)
                        s.temperature = d.temperatureAndTintValues(for: g).temperature
                    }
                    s.flash = d.hasFlash
                    s.megapixels = Self.megapixels(self.output.maxPhotoDimensions)
                    s.sizes = Array(Set(f.supportedMaxPhotoDimensions.map(Self.megapixels).filter { $0 >= 5 })).sorted()
                }
                s.proRAW = self.output.isAppleProRAWSupported
                s.bayer = self.bayerSupported
                done.resume(returning: s)
            }
        }
    }

    // MARK: capture

    /// One exposure. The file is ProRAW DNG, Bayer RAW DNG or HEIF, exactly as the camera wrote it.
    func capture(_ format: Format, flash: Flash) async throws -> Shot {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Shot, Error>) in
            queue.async {
                var rawSettings: AVCapturePhotoSettings?
                var raw = false
                let types = self.output.availableRawPhotoPixelFormatTypes
                if format == .proRAW, self.output.isAppleProRAWEnabled,
                   let type = types.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                    rawSettings = AVCapturePhotoSettings(rawPixelFormatType: type)
                    raw = true
                } else if format == .raw, !self.output.isAppleProRAWEnabled,
                          let type = types.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
                    // One sensor frame has no highlight room of its own (ProRAW's fusion has): taken 1 EV under the
                    // meter, a one-frame bracket so the viewfinder keeps its brightness. The film's own meter
                    // (auto exposure) brings the picture back up. Not with flash: a bracket takes none.
                    if flash == .off, self.output.maxBracketedCapturePhotoCount >= 1,
                       let d = self.input?.device {
                        let bias = max(d.exposureTargetBias - 1, d.minExposureTargetBias)
                        rawSettings = AVCapturePhotoBracketSettings(
                            rawPixelFormatType: type, processedFormat: nil,
                            bracketedSettings: [AVCaptureAutoExposureBracketedStillImageSettings
                                .autoExposureSettings(exposureTargetBias: bias)])
                    } else {
                        rawSettings = AVCapturePhotoSettings(rawPixelFormatType: type)
                    }
                    raw = true
                }
                let settings = rawSettings ?? (self.output.availablePhotoCodecTypes.contains(.hevc)
                    ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                    : AVCapturePhotoSettings())
                if format == .raw && raw {
                    // One frame off the sensor: its own (binned) size, and no multi-frame pipeline.
                    if let twelve = self.input?.device.activeFormat.supportedMaxPhotoDimensions
                        .first(where: { Self.megapixels($0) >= 11 }) { settings.maxPhotoDimensions = twelve }
                    settings.photoQualityPrioritization = .speed
                } else {
                    settings.maxPhotoDimensions = self.output.maxPhotoDimensions
                    settings.photoQualityPrioritization = .quality
                }
                let mode: AVCaptureDevice.FlashMode = flash == .on ? .on : flash == .auto ? .auto : .off
                if self.output.supportedFlashModes.contains(mode) { settings.flashMode = mode }
                if let connection = self.output.connection(with: .video) {
                    connection.videoRotationAngle = Self.rotationAngle()
                }
                let id = settings.uniqueID
                let zoom = Double(self.input?.device.videoZoomFactor ?? 1)
                let asked = Int(max(settings.maxPhotoDimensions.width, settings.maxPhotoDimensions.height))
                let delegate = PhotoDelegate(isRAW: raw, zoom: zoom, asked: asked) { [weak self] result in
                    self?.queue.async {
                        guard let self else { return }
                        self.inFlight[id] = nil
                        if self.inFlight.isEmpty, let (d, z) = self.waitingLens {
                            self.waitingLens = nil
                            if self.input?.device != d { _ = self.configure(d) }
                            self.applyZoom(z)
                        }
                    }
                    done.resume(with: result)
                }
                self.inFlight[id] = delegate
                self.output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// The photo's rotation from how the phone is held (portrait 90°, landscape 0° / 180°).
    nonisolated(unsafe) static var heldAngle: CGFloat = 90
    private static func rotationAngle() -> CGFloat { heldAngle }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let onFrame, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) { onFrame(pixels) }
        frameCount += 1
        guard frameCount % 6 == 0, let onHistogram, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var bins = [Float](repeating: 0, count: 64)
        let step = max(1, Int((Double(w * h) / 20_000).squareRoot()))
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = y * row + x * 4   // BGRA
                let l = (Int(p[o + 2]) * 54 + Int(p[o + 1]) * 183 + Int(p[o]) * 19) >> 8
                bins[min(63, l >> 2)] += 1
                x += step
            }
            y += step
        }
        let top = max(bins.max() ?? 1, 1)
        onHistogram(bins.map { $0 / top })
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let isRAW: Bool
    let zoom: Double
    let asked: Int
    let finish: (Result<CameraController.Shot, Error>) -> Void
    private var data: Data?

    init(isRAW: Bool, zoom: Double, asked: Int, finish: @escaping (Result<CameraController.Shot, Error>) -> Void) {
        self.isRAW = isRAW
        self.zoom = zoom
        self.asked = asked
        self.finish = finish
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil, !isRAW || photo.isRawPhoto { data = photo.fileDataRepresentation() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let data {
            finish(.success(CameraController.Shot(data: data, isRAW: isRAW, zoom: zoom, askedLongEdge: asked)))
        } else {
            finish(.failure(error ?? DecodeError.unreadable("相机没有返回照片")))
        }
    }
}

/// The phone's roll, for the level and for which way up a photo is written.
@MainActor
final class LevelMeter: ObservableObject {
    /// Degrees the horizon is tilted, −180…180 (0 = level in portrait).
    @Published private(set) var roll: Double = 0
    /// How far the camera's controls turn so they read upright, degrees (0, 90, -90): changes only when the phone
    /// is turned past 45° to a landscape side (upside down keeps portrait, as the Camera app does).
    @Published private(set) var uiTurn: Double = 0
    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            let angle = atan2(g.x, -g.y) * 180 / .pi
            MainActor.assumeIsolated {
                self?.roll = angle
                let turn: Double = abs(angle) < 45 || abs(angle) > 135 ? 0 : (angle > 0 ? -90 : 90)
                if self?.uiTurn != turn { self?.uiTurn = turn }
                // Which way up the photo is: portrait 90°, landscape left 0°, right 180°, upside down 270°.
                CameraController.heldAngle = abs(angle) < 45 ? 90 : abs(angle) > 135 ? 270 : angle > 0 ? 180 : 0
            }
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}

/// One way to shoot: a format at a size, with what it costs. ProRAW comes at 12 and 48 MP only.
struct CaptureMode: Identifiable, Hashable {
    let format: CameraController.Format
    let megapixels: Int
    var id: String { "\(format.rawValue)-\(megapixels)" }
    var title: String { "\(format.title) · \(megapixels) MP" }

    /// Rough file size and what the mode is for, in words a newcomer can choose by — the camera's format menu is
    /// the only place most people meet these (ProRAW ~1.6 MB a MP, HEIF ~0.2, single-frame RAW ~0.85, measured).
    var detail: String {
        let mb = Double(megapixels) * (format == .heif ? 0.2 : format == .raw ? 0.85 : 1.6)
        let size = mb >= 10 ? String(format: "约 %.0f MB", mb) : String(format: "约 %.1f MB", mb)
        switch (format, megapixels) {
        case (.heif, 40...): return size + " · 细节最多"
        case (.heif, 20...): return size + " · 细节和体积平衡"
        case (.heif, _): return size + " · 最省空间"
        case (.proRAW, 40...): return size + " · 后期空间最大"
        case (.proRAW, _): return size + " · 原始数据，文件小一些"
        case (.raw, _): return size
        }
    }

    /// The modes a lens offers: largest first, ProRAW, then single-frame RAW, then HEIF.
    static func available(sizes: [Int], proRAW: Bool, bayer: Bool = false) -> [CaptureMode] {
        let big = sizes.sorted(by: >)
        let pro = proRAW ? big.filter { $0 == 12 || $0 >= 40 }.map { CaptureMode(format: .proRAW, megapixels: $0) } : []
        let raw = bayer ? [CaptureMode(format: .raw, megapixels: 12)] : []
        return pro + raw + big.map { CaptureMode(format: .heif, megapixels: $0) }
    }

    /// Every mode an iPhone with a 48 MP camera has (for Settings, where no lens is open).
    static let all: [CaptureMode] = available(sizes: [48, 24, 12], proRAW: true, bayer: true)
}
