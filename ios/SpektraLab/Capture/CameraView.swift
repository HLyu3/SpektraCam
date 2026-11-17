//  CameraView.swift — load a roll, then shoot. Every frame goes straight to the wall,
//  developed later on the roll it was shot on.

import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct CameraView: View {
    @ObservedObject var model: ViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraController()
    /// Held, not observed: the meter publishes 30 times a second, and redrawing the whole page that often
    /// lost taps on its menus. Only `LevelOverlay` watches it.
    @State private var level = LevelMeter()
    @AppStorage("SpektraLab.cameraFormat") private var format = CameraController.Format.proRAW.rawValue
    @AppStorage("SpektraLab.cameraRoll") private var roll = StockCatalog.defaultFilm
    /// A paper picked in the 冲印 menu for this visit, and the roll it was picked for: another roll is on its
    /// recommended paper. Kept with its roll rather than cleared on a roll change — clearing it was a second update
    /// right after the roll's, and the roll shelf twitched.
    @State private var paperPick: (roll: String, paper: String)?
    private var rollPaper: String? { paperPick?.roll == roll ? paperPick?.paper : nil }
    /// The size to shoot, in MP; 0 = the lens's largest.
    @AppStorage("SpektraLab.cameraSizeMP") private var sizeMP = 0
    @AppStorage("SpektraLab.cameraFlash") private var flash = CameraController.Flash.off.rawValue
    @AppStorage("SpektraLab.cameraGrid") private var showGrid = true
    @AppStorage("SpektraLab.cameraLevel") private var showLevel = true
    @AppStorage("SpektraLab.cameraToPhotos") private var toPhotos = false
    @AppStorage("SpektraLab.haptics") private var haptics = true
    /// Develop every shot with the roll's look and put the print in Photos.
    @AppStorage(ViewModel.autoDevelopKey) private var autoDevelop = true
    /// The viewfinder in the roll's colours (a cube baked through the engine), or plain.
    @AppStorage("SpektraLab.cameraFilmLook") private var filmLook = true
    /// The lens row's labels: "x" zoom factors as the Camera app shows them (0.5, 1×, 2, 4), or "mm" focal lengths.
    @AppStorage("SpektraLab.cameraLensLabel") private var lensLabel = "x"
    @State private var finder = FilmViewfinderRenderer()
    @State private var baking = false
    @State private var choosingRoll = false
    @State private var choosingFormat = false
    @State private var savingCombo = false
    @State private var renaming: SavedRecipe?
    @State private var comboName = ""
    @State private var ready = false
    @State private var problem: String?
    @State private var pending = 0
    @State private var shot = 0
    @State private var blink = false
    @State private var last: UIImage?
    @State private var status = CameraController.Status()
    @State private var histogram = HistogramFeed()
    @State private var lens: String?
    /// The back camera's focal length, 35 mm equivalent: a lens and its digital zoom (`aim`).
    @State private var focal: Double = 24
    @State private var showingSettings = false
    /// The controls turned upright for how the phone is held (`LevelMeter.uiTurn`); the layout stays portrait.
    @State private var turn: Double = 0
    @State private var deletingLast = false
    /// The newest shot this camera put in the library (a 无胶卷 shot goes to Photos, not here).
    /// The last shot in 底片; nil when the last one was 无胶卷 (it went to Photos only).
    private var latestShot: LibraryPhoto? {
        lastPlain ? nil : model.library.filter(\.captured).max { $0.createdAt < $1.createdAt }
    }
    @State private var lastPlain = false
    /// Single-frame RAW cannot zoom in the sensor (and refuses any digital zoom): only the lenses' own lengths.
    private var lensesOnly: Bool { chosen == .raw }
    @State private var front = false
    @State private var pro = false
    @State private var proControl: ProControl = .exposure
    @State private var focusPoint: CGPoint?
    @State private var focusShown = 0
    @State private var dragFrom: Float?
    @State private var aeLocked = false
    @State private var viewfinderSize = CGSize.zero

    enum ProControl: String, CaseIterable { case exposure = "±EV", shutter = "快门", iso = "ISO", white = "色温" }

    private var chosen: CameraController.Format {
        let f = CameraController.Format(rawValue: format) ?? .proRAW
        if ready && f == .proRAW && !status.proRAW { return .heif }
        if ready && f == .raw && !status.bayer { return .heif }
        return f
    }

    /// The roll "" is no film: plain viewfinder, the camera's own file straight into Photos.
    private var noFilm: Bool { roll.isEmpty }

    /// What the roll prints on, under the strip.
    private var rollSubtitle: String {
        guard let look = model.rollRecipe(roll, paper: rollPaper) else { return "不冲洗 · 原始文件直接存进“照片”" }
        let paper = "相纸 · " + model.filmName(for: look.printStock)
        return roll.hasPrefix("recipe:") ? "配方 · \(model.filmName(for: look.filmStock)) · " + paper : paper
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            viewfinder
            lensDial
            Spacer(minLength: 4)
            rollCarousel
            shutterRow
        }
        // Format and size go to the camera together (one pipeline rebuild, `setMode`).
        .onChange(of: "\(format)|\(sizeMP)") { _, _ in
            // ProRAW comes at 12 or 48 MP; an older 24 MP choice under ProRAW becomes 48.
            if format == CameraController.Format.proRAW.rawValue, sizeMP == 24 { sizeMP = 48; return }
            camera.setMode(CameraController.Format(rawValue: format) ?? .proRAW, mp: sizeMP)
            if ready && !front { lens = nil; aim(focal) }      // RAW snaps to a lens; the others may zoom
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            camera.preferredMP = sizeMP
            camera.setFormat(CameraController.Format(rawValue: format) ?? .proRAW)
            let feed = histogram
            camera.onHistogram = { bins in Task { @MainActor in feed.bins = bins } }
            let finder = finder
            camera.onFrame = { finder.push($0) }
            problem = await camera.start()
            ready = problem == nil
            lens = camera.lenses.first { $0.device.deviceType == .builtInWideAngleCamera }?.id
            focal = Double(camera.lenses.first { $0.id == lens }?.millimetres ?? 24)
            level.start()
            while !Task.isCancelled {
                let next = await camera.status()
                if next != status { status = next }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        .onDisappear { camera.stop(); level.stop() }
        // The Camera Control button (and the volume buttons) is the shutter while this page is up.
        .onCameraCaptureEvent { event in
            if event.phase == .ended { shoot() }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
        .onReceive(level.$uiTurn) { t in withAnimation(.snappy(duration: 0.3)) { turn = t } }
        .confirmationDialog("删除刚拍的这张？", isPresented: $deletingLast, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let latest = latestShot {
                    model.deletePhotos([latest.id])
                    last = model.library.filter(\.captured).max { $0.createdAt < $1.createdAt }?.thumbnail
                    if shot > 0 { shot -= 1 }
                }
            }
        } message: {
            Text("Spektra Cam 里的底片会删掉；已经存进“照片”或冲洗好的成片不受影响。")
        }
        .alert("存为组合", isPresented: $savingCombo) {
            TextField("名称", text: $comboName)
            Button("保存") {
                if let look = model.rollRecipe(roll, paper: rollPaper) {
                    roll = model.saveCombination(look, named: comboName).roll
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这卷胶片和相纸会出现在胶卷栏最前面，点一下就能装上。")
        }
        .alert("重命名组合", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $comboName)
            Button("好") { if let r = renaming { model.renameRecipe(r.id, to: comboName) } }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $choosingRoll) {
            RollSheet(model: model, current: roll) { roll = $0 }.equatable()
        }
        // Picking a roll shows it: a new film under 实景 looked like "the film does nothing".
        .onChange(of: roll) { _, r in
            if !r.isEmpty { filmLook = true }
            // A paper picked off the recommendations is for its roll and this moment: gone once the roll changes
            // (switching back starts on the recommended paper again). It no longer applied the moment the roll
            // changed (`rollPaper`), so clearing it now moves nothing on the page.
            if paperPick != nil { paperPick = nil }
        }
        .task(id: filmLook ? "\(roll)|\(rollPaper ?? "")" : "") {      // a new paper is a new look
            guard filmLook, !noFilm else { finder.setCube(nil, size: 0); return }
            baking = true
            let cube = await model.viewfinderLUT(roll: roll, paper: rollPaper)
            finder.setCube(cube, size: ViewModel.viewfinderLUTSize)
            baking = false
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shot) { _, _ in haptics }
    }

    // MARK: top

    /// A camera's top plate: close and flash, the exposure as a little LCD (format, shutter, ISO, EV, the
    /// histogram behind them), and the settings menu.
    private var topBar: some View {
        HStack(spacing: 8) {
            roundButton("xmark", "关闭相机") { dismiss() }
            roundButton(flash == "on" ? "bolt.fill" : flash == "auto" ? "bolt.badge.automatic" : "bolt.slash", "闪光灯") { cycleFlash() }
                .opacity(status.flash ? 1 : 0.35)
                .disabled(!status.flash)
            formatMenu
            HStack(spacing: 10) {
                Text(shutterText(status.shutter))
                Text("ISO \(Int(status.iso))")
                if abs(status.bias) >= 0.05 { Text(String(format: "%+.1f", status.bias)) }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background {
                HistogramFeedView(feed: histogram).opacity(0.35).padding(.vertical, 3)
            }
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            Menu {
                Toggle("拍完自动冲洗", isOn: $autoDevelop)
                Toggle("同时存入“照片”", isOn: $toPhotos)
                Divider()
                Picker("镜头显示", selection: $lensLabel) {
                    Text("倍率（0.5 · 1 · 2 · 4）").tag("x")
                    Text("焦段（13 · 24 · 48 · 100 mm）").tag("mm")
                }
                Toggle("网格", isOn: $showGrid)
                Toggle("水平仪", isOn: $showLevel)
                Divider()
                Button { showingSettings = true } label: { Label("设置…", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .rotationEffect(.degrees(turn))
                    .frame(width: 36, height: 36)
                    .labGlassInteractive(in: Circle())
            }
            .accessibilityLabel("相机设置")
        }
        .foregroundStyle(Color.labCream)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func roundButton(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .rotationEffect(.degrees(turn))
                .frame(width: 36, height: 36)
                .labGlassInteractive(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 拍摄格式: this lens's formats at their sizes, beside the shutter.
    // A sheet, not a system menu: a menu showed the titles only, and these choices need their explanation.
    private var formatMenu: some View {
        Button { choosingFormat = true } label: {
            HStack(spacing: 3) {
                Text(chosen.title).font(.system(size: 11, weight: .heavy))
                if status.megapixels > 0, chosen != .raw {
                    Text("\(status.megapixels)").font(.system(size: 10, weight: .semibold, design: .monospaced)).opacity(0.75)
                }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(Color.labRed)
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("拍摄格式 \(chosen.title)，\(status.megapixels) MP，点按更改")
        .sheet(isPresented: $choosingFormat) {
            FormatSheet(modes: CaptureMode.available(sizes: status.sizes, proRAW: status.proRAW, bayer: status.bayer),
                        isOn: { $0.format == chosen && ($0.format == .raw || $0.megapixels == status.megapixels) },
                        pick: { mode in
                            format = mode.format.rawValue
                            sizeMP = mode.megapixels
                            choosingFormat = false
                        })
                .presentationDetents([.medium, .large])
                .presentationBackground(Color.labInk)
        }
    }

    // MARK: the picture

    private var viewfinder: some View {
        CameraPreview(session: camera.session, tap: { layerPoint, devicePoint in
            camera.focus(at: devicePoint)          // also back to no exposure bias, as Camera does
            status.bias = 0
            aeLocked = false
            focusPoint = layerPoint
            focusShown += 1
        }, drag: { points in
            // Up brighter, down darker: 1 EV every 90 points, within ±3 EV (the device's own limits apply too).
            guard let points else { dragFrom = nil; focusShown += 1; return }
            let from = dragFrom ?? status.bias
            dragFrom = from
            let ev = Float(min(max(Double(from) + Double(points) / 90, -3), 3))
            status.bias = ev
            camera.setBias(ev)
            if focusPoint == nil { focusPoint = CGPoint(x: viewfinderSize.width / 2, y: viewfinderSize.height / 2) }
        }, hold: { layerPoint, devicePoint in
            camera.lock(at: devicePoint)
            aeLocked = true
            focusPoint = layerPoint
            focusShown += 1
        })
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewfinderSize = $0 }
        // The focus box goes after a while, unless a drag holds it or AE/AF is locked.
        .task(id: focusShown) {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if dragFrom == nil, !aeLocked { focusPoint = nil }
        }
        .overlay { if filmLook && !noFilm { FilmViewfinder(renderer: finder).allowsHitTesting(false) } }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        // No pinch zoom (the owner, 2026-11-16): the lens stops (0.5 · 1 · 2 · 4 · 8, native or in-sensor) are where
        // the picture is best; finer framing is the editor's crop.
        .overlay(alignment: .topLeading) {
            // The preview's look, said in words: a roll shot under 实景 still develops on its film.
            if !noFilm {
                VStack(alignment: .leading, spacing: 4) {
                    Button { filmLook.toggle() } label: {
                        HStack(spacing: 5) {
                            if baking { ProgressView().controlSize(.mini).tint(filmLook ? Color.black : Color.labCream) }
                            else { Image(systemName: filmLook ? "film" : "eye") }
                            Text(filmLook ? "胶片预览" : "实景预览")
                            Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .bold)).opacity(0.6)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(filmLook ? Color.black : Color.labCream)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(filmLook ? AnyShapeStyle(Color.labCream) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    if !filmLook {
                        Text("取景是实景，拍出来仍是 \(model.rollTitle(roll))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.labCream)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
                .padding(10)
                .accessibilityLabel(filmLook ? "取景显示胶片效果，点按切换到实景" : "取景显示实景，拍出来仍套用胶卷，点按切换到胶片效果")
            }
        }
        .overlay { if showGrid { GridLines() } }
        .overlay { if showLevel { LevelOverlay(level: level) } }
        .overlay {
            if let focusPoint {
                // The focus box with Camera's sun beside it: the exposure the drag sets.
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(aeLocked ? Color.labRed : Color.labCream, lineWidth: 1.5)
                        .frame(width: 70, height: 70)
                    // Camera's exposure track: a line beside the box, the sun on it at the exposure (±3 EV over its
                    // length), the line broken where the sun sits.
                    let track: CGFloat = 110
                    let y = -CGFloat(status.bias) / 3 * (track / 2)
                    ZStack {
                        VStack(spacing: 0) {
                            Rectangle().frame(width: 1, height: max(0, track / 2 + y - 11))
                            Spacer(minLength: 22)
                            Rectangle().frame(width: 1, height: max(0, track / 2 - y - 11))
                        }
                        .frame(height: track)
                        .opacity(dragFrom != nil ? 0.9 : 0.5)
                        Image(systemName: "sun.max.fill").font(.system(size: 15))
                            .offset(y: y)
                        if dragFrom != nil {
                            Text(String(format: "%+.1f", status.bias))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .offset(x: 26, y: y)
                        }
                    }
                    .frame(width: 22, height: track)
                    .foregroundStyle(aeLocked ? Color.labRed : Color.labCream)
                }
                .offset(x: 14)
                .position(focusPoint)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if aeLocked {
                Text("AE/AF 锁定")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Color.labRed, in: Capsule())
                    .padding(.top, 44)
                    .allowsHitTesting(false)
            }
        }
        .overlay(Color.black.opacity(blink ? 0.9 : 0).allowsHitTesting(false))
        .overlay(alignment: .bottom) {
            if pro { proPanel.background(.ultraThinMaterial).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay(alignment: .topTrailing) {
            if !noFilm {
                // The frame counter, as a film camera's window shows it.
                Text("\(CameraBody.nextFrame)")
                    .rotationEffect(.degrees(turn))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.labRed)
                    .frame(minWidth: 30, minHeight: 26)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .padding(10)
                    .accessibilityLabel("下一格 \(CameraBody.nextFrame)")
            }
        }
        .clipped()
        .overlay {
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Color.labCream)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
    }

    /// Under the picture: manual (M) at the left, the focal lengths in the middle, the front camera at the right.
    private var lensDial: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.snappy) { pro.toggle() } } label: {
                Text("M")
                    .font(.system(size: 14, weight: .heavy))
                    .rotationEffect(.degrees(turn))
                    .foregroundStyle(pro ? Color.black : Color.labCream)
                    .frame(width: 36, height: 36)
                    .background(pro ? Color.labRed : Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pro ? "收起手动控制" : "手动控制")
            Spacer(minLength: 0)
            if !front {
                HStack(spacing: 2) {
                    ForEach(stops, id: \.self) { mm in
                        let on = nearestStop == mm
                        Button { aim(Double(mm)) } label: {
                            Text(lensText(on && abs(focal - Double(mm)) > 0.5 ? focal : Double(mm), selected: on))
                                .font(.system(size: on ? 14 : 12, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 4)
                                .rotationEffect(.degrees(turn))
                                .foregroundStyle(on ? Color.black : Color.labCream.opacity(0.8))
                                .frame(minWidth: 40, minHeight: 32)
                                .background(on ? Color.labRed : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(mm) 毫米，\(zoomText(Double(mm)))倍")
                    }
                }
                .padding(3)
                .background(Color.white.opacity(0.07), in: Capsule())
            } else {
                Text("前置").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: 36, height: 36)
        }
        .foregroundStyle(Color.labCream)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: pro

    private var proPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(ProControl.allCases, id: \.self) { c in
                    Button { proControl = c } label: {
                        Text(c.rawValue)
                            .font(.system(size: 12, weight: proControl == c ? .semibold : .medium))
                            .foregroundStyle(proControl == c ? Color.black : Color.labCream)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(proControl == c ? Color.labCream : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            proSlider
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var proSlider: some View {
        switch proControl {
        case .exposure:
            proRow(auto: nil, value: String(format: "%+.1f EV", status.bias)) {
                Slider(value: Binding(get: { Double(status.bias) },
                                      set: { status.bias = Float($0); camera.setBias(Float($0)) }),
                       in: Double(max(status.minBias, -3))...Double(min(status.maxBias, 3)), step: 0.1)
            }
        case .shutter:
            // Logarithmic: equal steps are equal stops.
            proRow(auto: status.manual ? { camera.setAutoExposure() } : nil, value: shutterText(status.shutter)) {
                Slider(value: Binding(get: { log2(max(status.shutter, 1e-6)) },
                                      set: { status.shutter = pow(2, $0); camera.setManual(shutter: pow(2, $0), iso: nil) }),
                       in: log2(status.minShutter)...log2(max(status.maxShutter, status.minShutter * 2)))
            }
        case .iso:
            proRow(auto: status.manual ? { camera.setAutoExposure() } : nil, value: "ISO \(Int(status.iso))") {
                Slider(value: Binding(get: { log2(Double(max(status.iso, 1))) },
                                      set: { status.iso = Float(pow(2, $0)); camera.setManual(shutter: nil, iso: Float(pow(2, $0))) }),
                       in: log2(Double(status.minISO))...log2(Double(max(status.maxISO, status.minISO * 2))))
            }
        case .white:
            proRow(auto: status.wbLocked ? { camera.setTemperature(nil) } : nil, value: "\(Int(status.temperature)) K") {
                Slider(value: Binding(get: { Double(status.temperature) },
                                      set: { status.temperature = Float($0); camera.setTemperature(Float($0)) }),
                       in: 2500...9000, step: 50)
            }
        }
    }

    /// A control row: the "A" switch (lit while automatic; tapping it while manual goes back to auto).
    private func proRow<S: View>(auto: (() -> Void)?, value: String, @ViewBuilder slider: () -> S) -> some View {
        HStack(spacing: 10) {
            Button { auto?() } label: {
                Text("A")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(auto == nil ? Color.black : Color.labCream)
                    .frame(width: 30, height: 30)
                    .background(auto == nil ? Color.labCream : Color.clear, in: Circle())
                    .overlay(Circle().stroke(Color.labCream, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(auto == nil ? "自动" : "恢复自动")
            slider().tint(Color.labRed)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.labCream)
                .frame(width: 66, alignment: .trailing)
        }
    }

    // MARK: roll and shutter

    /// The rolls as canisters on a shelf: no film, the saved recipes, the films (favourites first). The loaded one
    /// is lit and named underneath, with what it prints on; the grid at the end opens every roll.
    private var rollCarousel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            canister(id: "", on: roll.isEmpty) {
                                Image(systemName: "circle.slash").font(.system(size: 16, weight: .medium))
                            }
                            // Saved combinations first: their film's canister, a star in the corner.
                            ForEach(model.savedRecipes) { saved in
                                canister(id: saved.roll, on: saved.roll == roll) {
                                    if let film = model.catalog.stock(saved.recipe.filmStock) {
                                        StockArtwork(stock: film)
                                            .overlay(alignment: .topTrailing) {
                                                Image(systemName: "star.fill").font(.system(size: 8))
                                                    .foregroundStyle(Color.labRed)
                                                    .padding(2).background(Color.labInk, in: Circle())
                                                    .offset(x: 3, y: -3)
                                            }
                                    } else {
                                        Image(systemName: "wand.and.stars").font(.system(size: 16, weight: .medium))
                                    }
                                }
                                .contextMenu {
                                    Button { renaming = saved; comboName = saved.name } label: { Label("重命名", systemImage: "pencil") }
                                    Button(role: .destructive) {
                                        if roll == saved.roll { roll = saved.recipe.filmStock }
                                        model.deleteRecipe(saved.id)
                                    } label: { Label("删除组合", systemImage: "trash") }
                                }
                            }
                            ForEach(model.filmsFavouritesFirst) { film in
                                canister(id: film.id, on: film.id == roll) { StockArtwork(stock: film) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .onAppear { proxy.scrollTo(roll, anchor: .center) }
                    .onChange(of: roll) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                Button { choosingRoll = true } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.labCream)
                        .frame(width: 44, height: 50)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("全部胶卷")
            }
            VStack(spacing: 1) {
                Text(roll.isEmpty ? "无胶卷" : model.rollTitle(roll))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.labCream)
                // A film roll's paper is chosen here (the 相纸 chip) (the default paper, also in Settings); 推荐 marks its classic pairs.
                if !roll.isEmpty, !roll.hasPrefix("recipe:"), !model.catalog.isMonochrome(roll) {
                    let recommended = StockCatalog.recommendedPapers(for: roll)
                    let film = roll
                    PaperMenu(title: rollSubtitle,
                              current: model.rollRecipe(roll, paper: rollPaper)?.printStock ?? "",
                              papers: model.papers.filter { !$0.monochrome }.map { PaperMenu.Item(id: $0.id, name: $0.name) },
                              recommended: recommended,
                              pick: { id in
                                  // A recommended paper becomes this film's paper from now on; another, this visit only.
                                  if recommended.contains(id) { UserDefaults.standard.set(id, forKey: StockCatalog.filmPaperKey(film)) }
                                  paperPick = (film, id)
                              },
                              save: {
                                  if let look = model.rollRecipe(roll, paper: rollPaper) {
                                      comboName = "\(model.shortFilmName(for: look.filmStock)) · \(model.shortFilmName(for: look.printStock))"
                                      savingCombo = true
                                  }
                              })
                    .equatable()
                } else {
                    Text(rollSubtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            // Name and paper centred on the screen; the star at the row's edge, out of the way of the symmetry.
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if !roll.isEmpty { favouriteButton.padding(.trailing, 14) }
            }
        }
    }

    /// The combination on now (a saved one, or a film on a paper that one was saved as).
    private var currentCombination: SavedRecipe? {
        if roll.hasPrefix("recipe:") { return model.savedRecipes.first { $0.roll == roll } }
        guard let look = model.rollRecipe(roll, paper: rollPaper) else { return nil }
        return model.savedRecipes.first { $0.recipe.filmStock == look.filmStock && $0.recipe.printStock == look.printStock }
    }

    /// One tap keeps the film + paper on now as a favourite combination (first on the shelf); on a favourite, takes
    /// it off again.
    private var favouriteButton: some View {
        let saved = currentCombination
        return Button {
            if let saved {
                if roll == saved.roll { roll = saved.recipe.filmStock }
                model.deleteRecipe(saved.id)
            } else if let look = model.rollRecipe(roll, paper: rollPaper) {
                roll = model.saveCombination(look, named: "").roll
            }
        } label: {
            Image(systemName: saved != nil ? "star.fill" : "star")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(saved != nil ? Color.labRed : Color.labCream.opacity(0.8))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved != nil ? "取消收藏这个组合" : "收藏这个胶卷和相纸的组合")
    }

    private func canister<V: View>(id: String, on: Bool, @ViewBuilder face: () -> V) -> some View {
        Button { roll = id } label: {
            face()
                .frame(width: 34, height: 44)
                .rotationEffect(.degrees(turn))
                .foregroundStyle(Color.labCream.opacity(0.8))
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.labRed : .clear, lineWidth: 2))
                .scaleEffect(on ? 1.12 : 1)
                .opacity(on ? 1 : 0.7)
                .animation(.snappy(duration: 0.2), value: on)
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityLabel(id.isEmpty ? "无胶卷" : model.rollTitle(id))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var shutterRow: some View {
        HStack {
            ZStack {
                if let last {
                    Image(uiImage: last).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                }
                if pending > 0 { ProgressView().tint(.white) }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .rotationEffect(.degrees(turn))
            .overlay(alignment: .topTrailing) {
                if shot > 0 {
                    Text("\(shot)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.labRed, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
            .overlay(alignment: .bottom) {
                if model.developPending > 0 {
                    Text("冲洗中 \(model.developPending)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.labCream, in: Capsule())
                        .fixedSize()
                        .offset(y: 14)
                }
            }
            // Back to the library, shot or not (the tab bar's camera returns to 底片).
            .onTapGesture { dismiss() }
            // Long press: the last shot in the library — open it in the editor, or delete it.
            .contextMenu {
                if let latest = latestShot {
                    Button {
                        dismiss()
                        Task { @MainActor in await model.openLibraryPhoto(latest.id) }
                    } label: { Label("打开编辑", systemImage: "slider.horizontal.3") }
                    Button(role: .destructive) { deletingLast = true } label: { Label("删除刚拍的这张", systemImage: "trash") }
                }
                Button { dismiss() } label: { Label("回到图库", systemImage: "photo.stack") }
            }
            .accessibilityLabel("回到图库")
            .accessibilityLabel(model.developPending > 0 ? "回到照片墙，冲洗中 \(model.developPending) 张" : "回到照片墙")
            Spacer()
            Button(action: shoot) {
                ZStack {
                    Circle().stroke(Color.labCream, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(Color.labCream).frame(width: 62, height: 62)
                    Circle().fill(Color.labRed).frame(width: 10, height: 10).opacity(noFilm ? 0 : 1)
                        .scaleEffect(blink ? 0.85 : 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .accessibilityLabel("拍摄")
            Spacer()
            Button {
                front.toggle()
                if front, let f = camera.frontLens { camera.use(f.device) }
                else { lens = nil; aim(focal) }      // back to the back camera at the focal length it had
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .rotationEffect(.degrees(turn))
                    .foregroundStyle(Color.labCream)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(camera.frontLens == nil)
            .accessibilityLabel("切换前后摄像头")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func cycleFlash() {
        let all = CameraController.Flash.allCases
        let i = all.firstIndex { $0.rawValue == flash } ?? 0
        flash = all[(i + 1) % all.count].rawValue
    }

    private func shutterText(_ s: Double) -> String {
        guard s > 0 else { return "" }
        return s >= 0.5 ? String(format: "%.1f s", s) : "1/\(Int((1 / s).rounded())) s"
    }

    // MARK: focal length

    /// The stops in the lens row: each lens's own, and twice the main and the telephoto (Apple's 2× and 8×).
    private var stops: [Int] {
        let own = camera.lenses.map(\.millimetres)
        let main = camera.lenses.first { $0.device.deviceType == .builtInWideAngleCamera }?.millimetres
        let tele = camera.lenses.first { $0.device.deviceType == .builtInTelephotoCamera }?.millimetres
        if lensesOnly { return own }
        return Array(Set(own + [main, tele].compactMap { $0.map { $0 * 2 } })).sorted()
    }

    /// The main camera's focal length: 1× (24 mm on a 48 MP main camera, 26 before).
    private var mainMM: Double {
        Double(camera.lenses.first { $0.device.deviceType == .builtInWideAngleCamera }?.millimetres ?? 24)
    }

    /// A focal length as the Camera app names its zoom: 0.5, 1, 2, 4, 8; between stops one decimal (1.7).
    private func zoomText(_ mm: Double) -> String {
        let f = mm / mainMM
        // Apple's names for its lenses: 100 mm over a 24 mm main is 4.17, called 4; 13 mm is 0.54, called 0.5.
        if let named = [0.5, 1, 2, 3, 4, 5, 8, 10].first(where: { abs(f / $0 - 1) < 0.1 }) {
            return named < 1 ? "0.5" : "\(Int(named))"
        }
        return String(format: "%.1f", f)
    }

    /// A lens row label: the zoom (the chosen one with ×, as the Camera app does) or the focal length.
    private func lensText(_ mm: Double, selected: Bool) -> String {
        if lensLabel == "mm" { return "\(Int(mm.rounded()))" }
        // "0.5" in full (the owner prefers it to Camera's ".5"); the label is fixed-size, so it is never cut off.
        return zoomText(mm) + (selected ? "×" : "")
    }

    private var nearestStop: Int? {
        stops.min { abs(log(Double($0) / focal)) < abs(log(Double($1) / focal)) }
    }

    /// Go to a focal length: the longest lens at or under it, zoomed the rest of the way.
    private func aim(_ mm: Double) {
        let lenses = camera.lenses
        guard let widest = lenses.first else { return }
        let longest = lenses.last!
        var target = min(max(mm, Double(widest.millimetres)), Double(longest.millimetres) * 4)
        var pick = lenses.last { Double($0.millimetres) <= target + 0.01 } ?? widest
        if lensesOnly {
            // the nearest lens, at its own length
            pick = lenses.min { abs(log(Double($0.millimetres) / target)) < abs(log(Double($1.millimetres) / target)) } ?? widest
            target = Double(pick.millimetres)
        }
        focal = target
        let changed = lens != pick.id
        lens = pick.id
        if changed { camera.use(pick.device, zoom: target / Double(pick.millimetres)) }
        else { camera.setZoom(target / Double(pick.millimetres)) }
    }

    private func shoot() {
        pending += 1
        withAnimation(.easeOut(duration: 0.06)) { blink = true }
        withAnimation(.easeIn(duration: 0.2).delay(0.06)) { blink = false }
        var shotLook = model.rollRecipe(roll, paper: rollPaper)
        // The exposure dragged in the viewfinder (the sun) is the photographer's: kept in the photo as its exposure
        // compensation, on top of the develop's own meter — which otherwise re-metered it away. Not in manual mode.
        if !status.manual, abs(status.bias) >= 0.05 {
            shotLook?.params[FilmParam.exposureCompensation.key] = (Double(status.bias) * 10).rounded() / 10
        }
        let format = chosen, film = roll, look = shotLook, develop = autoDevelop, flashMode = CameraController.Flash(rawValue: flash) ?? .off, save = toPhotos
        Task {
            defer { pending -= 1 }
            do {
                let result = try await camera.capture(format, flash: flashMode)
                let thumb = film.isEmpty
                    ? await model.addShotToPhotos(result.data, isRAW: result.isRAW)
                    : await model.addCapturedShot(result.data, isRAW: result.isRAW, look: look ?? .standard, toPhotos: save,
                                                  develop: develop, zoom: result.zoom, askedLongEdge: result.askedLongEdge)
                if let thumb {
                    last = thumb
                    lastPlain = film.isEmpty
                    shot += 1
                }
            } catch {
NSLog("SpektraLab capture failed: %@", String(describing: error))
                problem = "拍摄失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - pieces

/// The camera's live picture; a tap reports the point on the view and on the sensor.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var tap: (CGPoint, CGPoint) -> Void = { _, _ in }
    /// As in Camera: a vertical drag on the picture moves the exposure (`nil` when it ends; else the points dragged,
    /// up positive), and a long press locks focus and exposure at the point.
    var drag: (CGFloat?) -> Void = { _ in }
    var hold: (CGPoint, CGPoint) -> Void = { _, _ in }

    final class PreviewView: UIView, UIGestureRecognizerDelegate {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var tap: (CGPoint, CGPoint) -> Void = { _, _ in }
        var drag: (CGFloat?) -> Void = { _ in }
        var hold: (CGPoint, CGPoint) -> Void = { _, _ in }
        @objc func tapped(_ g: UITapGestureRecognizer) {
            let p = g.location(in: self)
            tap(p, preview.captureDevicePointConverted(fromLayerPoint: p))
        }
        @objc func panned(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began, .changed: drag(-g.translation(in: self).y)
            default: drag(nil)
            }
        }
        @objc func held(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            let p = g.location(in: self)
            hold(p, preview.captureDevicePointConverted(fromLayerPoint: p))
        }
        /// Vertical starts only: a sideways or pinching hand is not changing the exposure.
        override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: self)
            return abs(v.y) > abs(v.x)
        }
        /// The pinch to zoom (SwiftUI's) runs beside these.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UIPinchGestureRecognizer
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(PreviewView.tapped(_:))))
        let pan = UIPanGestureRecognizer(target: view, action: #selector(PreviewView.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = view
        view.addGestureRecognizer(pan)
        let press = UILongPressGestureRecognizer(target: view, action: #selector(PreviewView.held(_:)))
        press.minimumPressDuration = 0.6
        press.delegate = view
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.tap = tap
        view.drag = drag
        view.hold = hold
    }
}

struct HistogramView: View {
    let bins: [Float]
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(.white.opacity(0.06)))
            guard bins.count > 1 else { return }
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in bins.enumerated() {
                p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(bins.count - 1),
                                      y: size.height * (1 - CGFloat(v) * 0.9)))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            ctx.fill(p, with: .color(.white.opacity(0.45)))
        }
        .accessibilityHidden(true)
    }
}

struct GridLines: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// A horizon line that turns with the phone, and goes the app's red when it is level.
struct LevelLine: View {
    let roll: Double
    var body: some View {
        // Nearest of the four ways to hold the phone.
        let target = (roll / 90).rounded() * 90
        let off = roll - target
        let flat = abs(off) < 1
        HStack(spacing: 6) {
            Rectangle().frame(width: 12, height: 1.5)
            Rectangle().frame(width: 90, height: 1.5).rotationEffect(.degrees(flat ? 0 : -off))
            Rectangle().frame(width: 12, height: 1.5)
        }
        .foregroundStyle(flat ? Color.labRed : Color.white.opacity(0.7))
        .rotationEffect(.degrees(-target))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The roll grid, kept out of the camera's own redraws: the level meter and the status poll redraw
/// `CameraView` many times a second, and a sheet rebuilt under a scroll made scrolling back up stutter.
private struct RollSheet: View, @MainActor Equatable {
    let model: ViewModel
    let current: String
    let pick: (String) -> Void
    static func == (a: Self, b: Self) -> Bool { a.current == b.current }
    var body: some View { StockBrowser(model: model, papers: false, current: current, pickFilm: pick) }
}

/// The live histogram's bins, watched only by the histogram itself (not the whole camera page).
@MainActor
final class HistogramFeed: ObservableObject {
    @Published var bins: [Float] = []
}

private struct HistogramFeedView: View {
    @ObservedObject var feed: HistogramFeed
    var body: some View { HistogramView(bins: feed.bins) }
}

private struct LevelOverlay: View {
    @ObservedObject var level: LevelMeter
    var body: some View { LevelLine(roll: level.roll) }
}

/// The 相纸 chip: opens `PaperSheet`. Apart from the camera page and equal by what it shows, so the page's frequent
/// redraws (its readouts) leave it alone. A system menu was used first: its frosted backdrop blurred the live
/// viewfinder behind it, and ghosted and flashed while scrolled (worse right after a roll change, as the film preview
/// reloads), so the list is an opaque sheet.
struct PaperMenu: View, @MainActor Equatable {
    struct Item: Equatable, Identifiable { let id: String; let name: String }
    let title: String
    let current: String
    let papers: [Item]
    let recommended: [String]
    let pick: (String) -> Void
    let save: () -> Void
    @State private var open = false

    static func == (a: PaperMenu, b: PaperMenu) -> Bool {
        a.title == b.title && a.current == b.current && a.papers == b.papers && a.recommended == b.recommended
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.labCream.opacity(0.85))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("相纸：\(title)，点按更换")
        .sheet(isPresented: $open) {
            PaperSheet(current: current, papers: papers, recommended: recommended,
                       pick: { pick($0); open = false },
                       save: { open = false; save() })
                .presentationDetents([.medium, .large])
                .presentationBackground(Color.labInk)
        }
    }
}

/// 拍摄格式: every size this lens offers, each with what it is for, grouped by format.
struct FormatSheet: View {
    let modes: [CaptureMode]
    let isOn: (CaptureMode) -> Bool
    let pick: (CaptureMode) -> Void

    private static let order: [(CameraController.Format, String, String)] = [
        (.heif, "HEIF · 日常推荐", "和原相机一样把几帧合成一张、降噪，最干净，文件小。随手拍、室内、夜景都用它。"),
        (.proRAW, "ProRAW · 认真拍时用", "也是多帧合成，但存成 RAW，亮处和暗处留得更多：逆光、天空很亮、反差大的场景，冲洗出的高光过渡更像胶片。文件很大。"),
        (.raw, "RAW · 单帧原始", "只读传感器的一帧，不合成、不降噪、不锐化。白天光线足时颗粒最原始；暗光和长焦下噪点很多，不推荐日常用。"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Self.order, id: \.0) { item in
                    let (format, title, note) = item
                    let rows = modes.filter { $0.format == format }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { mode in
                                Button { pick(mode) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(mode.title).foregroundStyle(Color.labCream)
                                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if isOn(mode) { Image(systemName: "checkmark").foregroundStyle(Color.labRed) }
                                    }
                                }
                            }
                        } header: {
                            Text(title)
                        } footer: {
                            Text(note)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("拍摄格式")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

/// The papers, the film's recommended ones first.
struct PaperSheet: View {
    let current: String
    let papers: [PaperMenu.Item]
    let recommended: [String]
    let pick: (String) -> Void
    let save: () -> Void

    var body: some View {
        let top = recommended.compactMap { id in papers.first { $0.id == id } }
        let rest = papers.filter { !recommended.contains($0.id) }
        NavigationStack {
            List {
                if !top.isEmpty {
                    Section("这卷胶片推荐") { ForEach(top) { row($0) } }
                }
                Section(top.isEmpty ? "相纸" : "其他相纸") { ForEach(rest) { row($0) } }
                Section {
                    Button(action: save) { Label("把胶卷和这张相纸存为组合…", systemImage: "star") }
                } footer: {
                    Text("推荐相纸里选的那张会记住，下次拍这卷还用它；推荐以外的只在这次拍摄有效。")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("相纸")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ paper: PaperMenu.Item) -> some View {
        Button { pick(paper.id) } label: {
            HStack {
                Text(paper.name).foregroundStyle(Color.labCream)
                Spacer()
                if paper.id == current { Image(systemName: "checkmark").foregroundStyle(Color.labRed) }
            }
        }
    }
}
