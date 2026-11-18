//  ContentView.swift — the engine's picture, chosen from a scrolling strip.
//
//  This is the real SpektraLab pipeline: the frame goes to `spk_open`, the
//  enlarger is solved, and the print is rendered by the C++/Metal engine into
//  a texture that MetalCanvas draws with the engine's output transform.
//  Every film and paper here is a measured profile from
//  `<resources>/profiles`, and every slider is an engine parameter.
//
//  What changed is only how those choices are reached. The two list sheets
//  are gone; films, papers and the parameter controls now live in a bottom
//  deck with a horizontal strip, so the picture stays on screen while a
//  person swipes through them.

import SwiftUI
import PhotosUI
import MetalKit
import UIKit
import UniformTypeIdentifiers

extension Color {
    /// Warm graphite, the darkroom's walls (the app's own look since 2026-11-16, not the community app's).
    static var labInk: Color { Color(red: 0.062, green: 0.059, blue: 0.055) }
    static var labPanel: Color { Color(red: 0.112, green: 0.106, blue: 0.098) }
    /// Paper white.
    static var labCream: Color { Color(red: 0.965, green: 0.945, blue: 0.905) }
    /// The accent: a safelight through an amber filter. Named `labRed` from the old palette (every screen uses it).
    static var labRed: Color { Color(red: 0.937, green: 0.604, blue: 0.188) }
}

extension View {
    /// Liquid Glass on iOS 26 and later; the same layout in a material on iOS 18 (Apple went from 18 to 26; 18 is the minimum).
    @ViewBuilder
    nonisolated func labGlass<S: Shape>(_ active: Bool = true, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(active ? .regular : .clear, in: shape)
        } else if active {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
        } else {
            self
        }
    }

    @ViewBuilder
    nonisolated func labGlassInteractive<S: Shape>(_ active: Bool = true, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(active ? .regular.interactive() : .clear, in: shape)
        } else if active {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
        } else {
            self
        }
    }

    /// A tinted glass surface. Used for the one primary action on a screen
    /// (add photos, paste a recipe), so the rest of the chrome stays neutral.
    @ViewBuilder
    nonisolated func labGlassTint<S: Shape>(_ tint: Color, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            background(tint.opacity(0.42), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}

/// Glass buttons that blend into each other on iOS 26; a plain group before it.
struct LabGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The darkroom: warm graphite, a faint amber safelight from the top, and film grain over all of it. The grain
/// is a small noise tile made once in code (no image asset) and tiled.
struct LabBackdrop: View {
    var body: some View {
        ZStack {
            Color.labInk
            RadialGradient(colors: [Color.labRed.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.5, y: -0.08), startRadius: 10, endRadius: 520)
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
            Image(uiImage: Self.grain)
                .resizable(resizingMode: .tile)
                .opacity(0.055)
                .blendMode(.screen)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// 192 px of luminance noise, a little clumped like grain (each speck drawn at a random size).
    static let grain: UIImage = {
        let side = 192
        let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; return f
        }())
        return r.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<(side * side / 3) {
                let v = CGFloat.random(in: 0.2...1, using: &rng)
                UIColor(white: v, alpha: CGFloat.random(in: 0.25...0.9, using: &rng)).setFill()
                let d = CGFloat.random(in: 0.6...1.8, using: &rng)
                ctx.fill(CGRect(x: CGFloat.random(in: 0..<CGFloat(side), using: &rng),
                                y: CGFloat.random(in: 0..<CGFloat(side), using: &rng), width: d, height: d))
            }
        }
    }()
}

struct EditorView: View {
    @EnvironmentObject private var model: ViewModel
    @State private var showingExport = false
    @State private var showingDiagnostics = false
    @State private var hiddenError: String?
    @State private var stage: EditStage = .film
    @State private var chosenTool: [EditStage: String] = [:]
    @State private var immersive = false
    @State private var zoom: CGFloat = 1
    @State private var savedZoom: CGFloat = 1
    @State private var pan = CGSize.zero
    /// The zoom hint: shown for a moment the first time a photo is zoomed past 1.5×, then not again for that photo.
    @State private var zoomHint = false
    @State private var zoomHintDone = false
    @State private var savedPan = CGSize.zero
    @State private var copyToast = false
    @State private var cropImage: CropImage?
    @State private var browsingPapers: Bool?
    @State private var savingRecipe = false
    @AppStorage(ViewModel.histogramKey) private var showHistogram = false
    @State private var recipeName = ""
    /// Long-press on the picture: the imported photograph while the finger is down.
    @GestureState private var comparing = false
    @State private var compareEndedAt = Date.distantPast

    var body: some View {
        ZStack(alignment: .bottom) {
            LabBackdrop()

            VStack(spacing: 0) {
                if !immersive {
                    topBar
                        .disabled(model.exporting || model.openingPreview != nil)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                picture
                    // Every photo opens whole: the last one's zoom is not kept (the owner, 2026-11-17). Here, not on
                    // the canvas: that is rebuilt on every render (`.id(renderIdentity)`).
                    .onChange(of: model.editingPhotoID) { _, _ in
                        zoom = 1; savedZoom = 1; pan = .zero; savedPan = .zero; zoomHint = false; zoomHintDone = false
                    }
                    .onChange(of: zoom > 1.5) { _, past in
                        guard past, !zoomHintDone else { return }
                        zoomHintDone = true
                        withAnimation(.easeOut(duration: 0.2)) { zoomHint = true }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            withAnimation(.easeOut(duration: 0.4)) { zoomHint = false }
                        }
                    }
                    .onAppear { zoom = 1; savedZoom = 1; pan = .zero; savedPan = .zero }
                if !immersive {
                    EditorDeck(model: model,
                               context: EditContext(
                                openCrop: {
                                    if let image = model.cropSourceImage() { cropImage = CropImage(image: image) }
                                },
                                browseStocks: { browsingPapers = $0 }),
                               stage: $stage, chosen: $chosenTool)
                        .disabled(model.exporting)
                        .opacity(model.exporting ? 0.45 : 1)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .disabled(model.openingPreview != nil)      // until the engine has the photo
                }
            }

            if !immersive, let why = failureMessage {
                notice(why)
            }

            if immersive {
                Button {
                    withAnimation(.snappy(duration: 0.24)) { immersive = false }
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .labGlassInteractive(in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.labCream)
                .padding(.trailing, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity)
            }

            if model.exporting {
                // Modal: nothing on the page may touch the engine until the file is written.
                ZStack {
                    Color.black.opacity(0.62)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .onLongPressGesture(minimumDuration: 0) {}
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.labCream)
                        Text(String(localized: "正在导出"))
                            .font(.headline)
                            .foregroundStyle(Color.labCream)
                        Text(model.statusText)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(String(localized: "完成前请不要切换 App"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(24)
                    .frame(maxWidth: 280)
                    .labGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .transition(.opacity)
                .zIndex(10)
                .accessibilityAddTraits(.isModal)
            }

            if copyToast {
                Text(String(localized: "配方已复制"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.labCream)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 38)
                    .labGlass(in: Capsule())
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 66)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.24), value: immersive)
        .statusBarHidden(immersive)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingExport) { ExportSheet(model: model) }
        .sheet(isPresented: $showingDiagnostics) { diagnosticsSheet }
        .alert(String(localized: "存为配方"), isPresented: $savingRecipe) {
            TextField(String(localized: "名字"), text: $recipeName)
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "存")) { model.saveCurrentRecipe(named: recipeName) }
        } message: {
            Text(String(localized: "胶片、相纸、曝光、效果、片边、日期和后期都会存进去；裁剪不会。"))
        }
        .sheet(item: Binding(get: { browsingPapers.map(BrowseStocks.init) }, set: { browsingPapers = $0?.papers })) {
            StockBrowser(model: model, papers: $0.papers)
        }
        .fullScreenCover(item: $cropImage) { item in
            CropScreen(image: item.image,
                       onDone: { model.setCrop($0); cropImage = nil },
                       onCancel: { cropImage = nil },
                       crop: model.crop)
        }
#if DEBUG
        .task {
            let environment = ProcessInfo.processInfo.environment
            if let film = environment["SPEKTRAFILM_UI_TEST_FILM"], !film.isEmpty {
                model.filmChanged(film)
                try? await Task.sleep(for: .seconds(2))
            }
            if let paper = environment["SPEKTRAFILM_UI_TEST_PAPER"], !paper.isEmpty {
                model.paperChanged(paper)
                try? await Task.sleep(for: .seconds(2))
            }
            if let gate = environment["SPEKTRAFILM_UI_TEST_GATE"], !gate.isEmpty {
                model.setOverscanFormat(gate)
            }
            if let orientation = environment["SPEKTRAFILM_UI_TEST_ORIENTATION"],
               let requested = FilmStripOrientation(rawValue: orientation) {
                model.setStripOrientation(requested)
            }
            if environment["SPEKTRAFILM_UI_TEST_BORDER"] == "1" {
                model.setFilmBorderEnabled(true)
                try? await Task.sleep(for: .seconds(8))
            }
            if environment["SPEKTRAFILM_UI_TEST_DATE"] == "1" {
                model.setDateBackEnabled(true)
                try? await Task.sleep(for: .seconds(6))
            }

            if environment["SPEKTRAFILM_UI_TEST_IMMERSIVE"] == "1" {
                immersive = true
            }
            if let value = environment["SPEKTRAFILM_UI_TEST_ZOOM"],
               let requested = Double(value) {
                zoom = min(max(CGFloat(requested), 1), 4)
                savedZoom = zoom
            }
            if let value = environment["SPEKTRAFILM_UI_TEST_EXPOSURE"],
               let requested = Double(value) {
                model.parameterChanged(FilmParam.exposureCompensation.key, requested)
                try? await Task.sleep(for: .seconds(8))
            }
        }
#endif
    }

    // MARK: - top bar

    /// Back, the film and paper (to the 胶片 stage), and the whole-photo actions: undo, redo,
    /// export, more. Tools live in the deck, never here.
    private var topBar: some View {
        HStack(spacing: 6) {
            Button { model.closeEditor() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .labGlassInteractive(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "返回照片墙"))

            Button {
                withAnimation(.easeOut(duration: 0.18)) { stage = .film; chosenTool[.film] = "film" }
            } label: {
                VStack(spacing: 1) {
                    Text(model.currentLookName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.labCream)
                    Text(model.recipe.noFilm == true ? String(localized: "原图，不经过胶片") : model.currentPaperName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.78))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.recipe.noFilm == true ? String(localized: "无胶片，原图")
                                : String(localized: "当前胶片 \(model.currentLookName)，相纸 \(model.currentPaperName)"))
            .labGlassInteractive(in: Capsule())

            HStack(spacing: 0) {
                barButton("arrow.uturn.backward", label: String(localized: "撤销"), enabled: model.canUndo && !isBusy) { model.undo() }
                barButton("arrow.uturn.forward", label: String(localized: "重做"), enabled: model.canRedo && !isBusy) { model.redo() }
            }
            .labGlassInteractive(in: Capsule())

            Button { showingExport = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .labGlassInteractive(in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.renderedTexture == nil)
            .opacity(model.renderedTexture == nil ? 0.4 : 1)
            .accessibilityLabel(String(localized: "导出"))

            Menu {
                if let id = model.editingPhotoID {
                    Button {
                        model.copyRecipe(from: id)
                        copyToast = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            copyToast = false
                        }
                    } label: {
                        Label(String(localized: "复制这张照片的配方"), systemImage: "doc.on.doc")
                    }
                }
                Button { recipeName = model.currentLookName; savingRecipe = true } label: {
                    Label(String(localized: "存为配方…"), systemImage: "wand.and.stars")
                }
                Toggle(isOn: Binding(get: { showHistogram }, set: { showHistogram = $0; model.refreshHistogram() })) {
                    Label(String(localized: "直方图"), systemImage: "chart.bar.xaxis")
                }
                Button { showingDiagnostics = true } label: {
                    Label(String(localized: "诊断信息"), systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "更多"))
        }
        .tint(Color.labRed)
        .foregroundStyle(Color.labCream)
        .padding(.top, 3)
        .padding(.horizontal, 10)
    }

    // MARK: - the picture

    private var picture: some View {
        ZStack {
            // Opening: the photo's kept develop at once, until the engine has it (then the canvas, the same picture).
            if let opening = model.openingPreview {
                Color.black
                Image(uiImage: opening).resizable().scaledToFit()
                    .overlay(alignment: .bottom) {
                        ProgressView().controlSize(.small).tint(Color.labCream).padding(.bottom, 14)
                    }
                    .zIndex(2)
            }
            if model.renderedTexture != nil {
                GeometryReader { proxy in
                    MetalCanvas(renderer: model.renderer,
                                texture: model.renderedTexture,
                                zoom: zoom,
                                pan: pan)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        // MTLTexture is not Hashable; the engine's progress id is
                        // what tells SwiftUI the picture changed.
                        .id(model.renderIdentity)
                        .overlay {
                            // 白平衡's eyedropper: the tap's place on the picture (aspect-fit, unzoomed while picking).
                            if model.pickingNeutral, let t = model.renderedTexture {
                                Color.white.opacity(0.001)
                                    .contentShape(Rectangle())
                                    .onTapGesture(coordinateSpace: .local) { p in
                                        let area = proxy.size
                                        let k = min(area.width / CGFloat(t.width), area.height / CGFloat(t.height))
                                        let w = CGFloat(t.width) * k, h = CGFloat(t.height) * k
                                        model.pickNeutral(at: CGPoint(x: (p.x - (area.width - w) / 2) / w,
                                                                      y: (p.y - (area.height - h) / 2) / h))
                                    }
                                    .overlay(alignment: .top) {
                                        Label(String(localized: "点一块应该是灰色或白色的地方"), systemImage: "eyedropper")
                                            .font(.footnote.weight(.semibold))
                                            .padding(.horizontal, 12).frame(height: 32)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .padding(.top, 10)
                                            .allowsHitTesting(false)
                                    }
                            }
                        }
                        .overlay {
                            if let marks = model.recipe.watermarks, zoom <= 1, !model.showingOriginal,
                               let t = model.renderedTexture {
                                WatermarkOverlay(placements: marks, shelf: model.watermarkShelf,
                                                 picture: CGSize(width: t.width, height: t.height), area: proxy.size)
                            }
                        }
                        .simultaneousGesture(imageGestures)
                        .simultaneousGesture(pictureTapGesture)
                        .simultaneousGesture(compareGesture)
                        .onChange(of: comparing) { _, on in
                            if !on { compareEndedAt = Date() }
                            model.setShowingOriginal(on)
                        }
                        .onChange(of: model.pickingNeutral) { _, on in
                            if on { zoom = 1; savedZoom = 1; pan = .zero; savedPan = .zero }
                        }
                }
            } else {
                emptyState
            }

            // Zoomed in: the canvas is the preview develop (Settings › 预览尺寸), soft past 1×; the export is full size.
            // At the top: at the bottom the 原图 button and undo / redo covered it. Under the histogram when it is on.
            // Small, see-through, gone after 3 s and not repeated for the photo (the owner: it was in the way).
            if zoomHint, !immersive, model.renderedTexture != nil {
                VStack {
                    Text(String(localized: "预览图放大略模糊，导出是全尺寸"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.labCream.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .padding(.top, showHistogram && model.histogram != nil ? 86 : 10)
                        .padding(.horizontal, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // ⋯ › 直方图: over the picture's top-left corner, out of the way of the 原图 button.
            if showHistogram, let h = model.histogram, !immersive {
                VStack {
                    HStack {
                        HistogramPlot(channels: h)
                            .frame(width: 132, height: 62)
                            .padding(12)
                            .allowsHitTesting(false)
                        Spacer()
                    }
                    Spacer()
                }
                .transition(.opacity)
            }

            if model.renderedTexture != nil {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        // The film / paper card; 无胶片 has neither (the top capsule says so).
                        if model.recipe.noFilm != true {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(model.currentFilmName)]")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.labCream.opacity(0.94))
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Text(model.currentPaperName)
                                    .lineLimit(1)
                                if model.filmBorderEnabled {
                                    Text("·")
                                    Text(model.selectedGate.title)
                                    if model.stripOrientation != .automatic {
                                        Text("·")
                                        Text(model.stripOrientation.title)
                                    }
                                }
                            }
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.labCream.opacity(0.55))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                        }
                        Spacer()
                        if !immersive {
                            // Hold to see the imported photograph (also: long-press the picture).
                            Label(String(localized: "原图"), systemImage: model.showingOriginal ? "eye.fill" : "eye")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(model.showingOriginal ? Color.black : Color.labCream)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(model.showingOriginal ? AnyShapeStyle(Color.labCream) : AnyShapeStyle(.ultraThinMaterial),
                                            in: Capsule())
                                .fixedSize()
                                .contentShape(Capsule())
                                .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity,
                                                    perform: {}, onPressingChanged: { model.setShowingOriginal($0) })
                                .accessibilityLabel(String(localized: "按住看原图"))
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .transition(.opacity)
            }

            if isBusy {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(model.state == .importing ? String(localized: "读取中") : String(localized: "渲染中"))
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.labInk)
    }

    private func barButton(_ symbol: String, label: String, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.labCream.opacity(enabled ? 1 : 0.3))
                .frame(width: 38, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// `@GestureState` resets itself however the touch ends, so the original never sticks.
    private var compareGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($comparing) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
    }

    /// Lifting the finger after a compare is not a tap.
    private var endsCompare: Bool {
        model.showingOriginal || Date().timeIntervalSince(compareEndedAt) < 0.4
    }

    private var pictureTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                guard !endsCompare else { return }
                if zoom > 1 || pan != .zero {
                    withAnimation(.easeOut(duration: 0.2)) {
                        zoom = 1
                        savedZoom = 1
                        pan = .zero
                        savedPan = .zero
                    }
                } else {
                    withAnimation(.snappy(duration: 0.24)) { immersive.toggle() }
                }
            }
            .exclusively(before: TapGesture().onEnded {
                guard !endsCompare else { return }
                withAnimation(.snappy(duration: 0.24)) { immersive.toggle() }
            })
    }

    private var imageGestures: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    zoom = min(max(savedZoom * value, 1), 4)
                    if zoom <= 1 { pan = .zero }
                }
                .onEnded { _ in
                    savedZoom = zoom
                    if zoom <= 1 { savedPan = .zero }
                },
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard zoom > 1, !model.showingOriginal else { return }
                    pan = CGSize(width: savedPan.width + value.translation.width,
                                 height: savedPan.height + value.translation.height)
                }
                .onEnded { _ in savedPan = pan }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.labRed.opacity(0.14)).frame(width: 92, height: 92)
                Circle().stroke(Color.labRed.opacity(0.35), lineWidth: 1).frame(width: 92, height: 92)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.labRed)
            }
            VStack(spacing: 7) {
                Text(String(localized: "这张照片没有显示出来"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.labCream)
                Text(String(localized: "回到照片墙重新打开，或查看诊断信息。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.closeEditor()
            } label: {
                Label(String(localized: "返回照片墙"), systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22)
                    .frame(minHeight: 46)
                    .background(Color.labRed, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(colors: [Color.labRed.opacity(0.09), Color.clear],
                           center: .center, startRadius: 10, endRadius: 240)
        )
    }

    // MARK: - helpers

    private var isBusy: Bool {
        model.state == .rendering || model.state == .importing || model.exporting
    }

    private var failureMessage: String? {
        guard case .failed(let why) = model.state, why != hiddenError else { return nil }
        return why
    }

    private func notice(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.labRed)
                Text(why)
                    .font(.footnote)
                    .foregroundStyle(Color.labCream)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    hiddenError = why
                    model.dismissFailure()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            Button {
                showingDiagnostics = true
            } label: {
                Text(String(localized: "查看诊断信息"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.labRed)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.labRed.opacity(0.45), lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 300)   // above the deck
    }

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "把这段内容发给开发者，可以直接定位引擎侧的问题。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(model.diagnostics)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(16)
            }
            .navigationTitle(String(localized: "诊断"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "复制")) {
                        UIPasteboard.general.string = model.diagnostics
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - the engine's canvas

/// The engine's texture, drawn. `MTKView` is paused with an explicit
/// `draw()`: the app draws when a render lands, not sixty times a second.
struct MetalCanvas: UIViewRepresentable {
    let renderer: CanvasRenderer?
    let texture: MTLTexture?
    let zoom: CGFloat
    let pan: CGSize

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = renderer?.device
        view.colorPixelFormat = .rgba16Float      // the renderer's pipeline; past 1 only under Enable HDR
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        renderer?.redraw = { [weak view] in view?.setNeedsDisplay() }
        view.backgroundColor = UIColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1)
        view.clearColor = MTLClearColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1)
        view.contentMode = .scaleAspectFit
        // The engine writes sRGB transfer-encoded values, matching the
        // macOS host. Tagging the drawable with the same space keeps iOS from
        // applying an implicit conversion.
        // Display P3, as the engine renders the preview (`ParamDefaults`); extended for HDR's values past white.
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.extendedDisplayP3)
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        return view
    }

    /// `MTKView` has no intrinsic size, and a representable with no size
    /// proposal collapses to a zero-by-zero drawable even inside a ZStack
    /// that fills the screen. That made the canvas render at its old size and
    /// the composition look like a small card. Accept the proposed size, or
    /// the parent's dimensions when the proposal has no concrete value.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: MTKView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ view: MTKView, context: Context) {
        renderer?.setTexture(texture)
        renderer?.setViewport(zoom: zoom,
                              pan: CGPoint(x: pan.width, y: pan.height),
                              size: view.bounds.size)
#if DEBUG
        if ProcessInfo.processInfo.environment["SPEKTRAFILM_CANVAS_LOG"] == "1" {
            NSLog("SpektraLab canvas bounds=%@ drawable=%@ texture=%dx%d",
                  NSCoder.string(for: view.bounds),
                  NSCoder.string(for: view.drawableSize),
                  texture?.width ?? 0,
                  texture?.height ?? 0)
        }
#endif
        view.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        weak var renderer: CanvasRenderer?

        init(renderer: CanvasRenderer?) {
            self.renderer = renderer
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            renderer?.draw(in: view)
        }
    }
}

// MARK: - a slider

struct ParamSlider: View {
    let control: ParamControl
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(control.title).font(.footnote)
                Spacer()
                Text(formatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: control.range)
                .tint(Color.labRed)
        }
    }

    private var formatted: String {
        if control.key == FilmParam.exposureCompensation.key || control.key == FilmParam.printBrightness.key {
            return String(format: "%+.2f EV", value)
        }
        if control.key == FilmParam.highlightRoom.key || control.key == FilmParam.shadowRoom.key {
            return String(format: String(localized: "%.1f 档"), value)
        }
        if control.key == FilmParam.preflash.key {
            return String(format: "%.3f", value)
        }
        if control.range.lowerBound < 0 {
            return String(format: "%+.2f", value)
        }
        return String(format: "%.2f", value)
    }
}

// MARK: - one tile in the strip

/// A measured profile, shown on the user's own photo. The tint is only a
/// navigation cue: the picture itself is always rendered by the engine.
struct StockTile: View {
    let stock: Stock
    let selected: Bool
    /// A paper that is a classic pair for the photo's film (`StockCatalog.recommendedPapers`).
    var recommended = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                StockArtwork(stock: stock)
                    .frame(width: 44, height: 50)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.labRed)
                                .background(Color.labCream, in: Circle())
                                .offset(x: 4, y: -4)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(stock.name)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.labCream : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumScaleFactor(0.78)
                        .multilineTextAlignment(.leading)

                    Text(typeLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(selected ? Color.labRed : Color.secondary.opacity(0.65))
                        .lineLimit(1)
                }
                .frame(width: 108, alignment: .leading)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(width: 168, height: 58, alignment: .leading)
            .background(selected ? Color.labRed.opacity(0.12) : Color.white.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? Color.labRed : Color.white.opacity(0.08),
                            lineWidth: selected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: selected)
        .accessibilityLabel("\(stock.name)，\(typeLabel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var typeLabel: String {
        if stock.support == .paper { return stock.monochrome ? String(localized: "黑白相纸") : recommended ? String(localized: "相纸 · 推荐") : String(localized: "相纸") }
        if stock.monochrome { return String(localized: "黑白负片") }
        if stock.isCine { return String(localized: "电影负片") }
        return stock.type == .positive ? String(localized: "反转片") : String(localized: "负片")
    }
}

// MARK: - the physical film edge and date back

/// The controls behind the compact “片边 / 日期” chips. They stay out of the
/// preview strip until someone asks for them, because they change the
/// physical gate rather than the picture's colour look.
struct FilmEffectsSheet: View {
    @ObservedObject var model: ViewModel
    /// `.border` or `.date` alone, embedded in the editor's deck; `.all` as a sheet.
    enum Part { case all, border, date }
    var part: Part = .all
    @Environment(\.dismiss) private var dismiss
    @State private var dataDraft = ""
    @State private var edgeDraft = ""

    var body: some View {
        if part == .all { sheet } else { embedded }
    }

    private var embedded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if part == .border { borderSection } else { dateSection }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { dataDraft = model.shootingDataText; edgeDraft = model.edgeText }
        .onDisappear {
            model.setEdgeText(edgeDraft)
            if dataDraft != model.shootingDataText { model.setShootingDataText(dataDraft) }
        }
    }

    private var sheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text(String(localized: "让画面重新成为一段底片。片边、齿孔、格号、日期与拍摄数据都按上游引擎的曝光模型生成，并和照片一起显影。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    borderSection
                    dateSection
                }
                .padding(16)
            }
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle(String(localized: "片边与日期后背"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) {
                        model.setShootingDataText(dataDraft)
                        model.setEdgeText(edgeDraft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Color.labRed)
        .presentationDetents([.large])
        .presentationBackground(Color.labInk)
        .onAppear { dataDraft = model.shootingDataText; edgeDraft = model.edgeText }
        .onDisappear {
            model.setEdgeText(edgeDraft)
            if dataDraft != model.shootingDataText {
                model.setShootingDataText(dataDraft)
            }
        }
    }

    private var borderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(String(localized: "片边"), systemImage: "film")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.filmBorderEnabled },
                    set: { model.setFilmBorderEnabled($0) }))
                    .labelsHidden()
                    .tint(Color.labRed)
            }

            Text(String(localized: "片边文字"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(model.currentFilmName.uppercased(), text: $edgeDraft)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { model.setEdgeText(edgeDraft) }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Text(String(localized: "留空就印胶片名。建议用英文字母和数字，最多 24 个字符。"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(String(localized: "片幅"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    gateChip(id: FilmGateCatalog.automaticID,
                             title: String(localized: "自动"),
                             detail: model.selectedGate.title)
                    ForEach(FilmGateCatalog.gates.filter { !$0.manualOnly || $0.id == "135_sprocket" }) { gate in
                        gateChip(id: gate.id, title: gate.title, detail: gate.detail)
                    }
                }
            }

            // Engine 2.4.1's motion-picture gauges: their own row.
            Text(String(localized: "电影画幅（颜色在“胶片”里选，如 Vision3）"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(FilmGateCatalog.gates.filter { $0.manualOnly && $0.id != "135_sprocket" }) { gate in
                        gateChip(id: gate.id, title: gate.title, detail: gate.detail)
                    }
                }
            }

            Text(String(localized: "片边方向"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Picker(String(localized: "片边方向"), selection: Binding(
                get: { model.stripOrientation },
                set: { model.setStripOrientation($0) })) {
                ForEach(FilmStripOrientation.allCases) { orientation in
                    Text(orientation.title).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.stripOrientationAvailable)

            HStack(spacing: 6) {
                Image(systemName: model.selectedGate.isSquare ? "square" : "rectangle.split.2x1")
                Text(model.selectedGate.isSquare
                     ? String(localized: "方形片幅没有横竖之分；画面会以中心裁切到 1:1。")
                     : String(localized: "当前 \(model.gateDisplayName) · \(model.stripOrientation.detail)。为避免拉伸，画面会中心裁切到对应方向的片条，预览与导出使用同一构图。"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .effectCard()
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(String(localized: "日期后背"), systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.dateBackEnabled },
                    set: { model.setDateBackEnabled($0) }))
                    .labelsHidden()
                    .tint(Color.labRed)
                    .disabled(!model.dateBackAvailable)
            }

            if !model.dateBackAvailable {
                Text(String(localized: "这个全景片幅在真实相机上没有日期后背，引擎会忽略日期曝光。"))
                    .font(.caption2)
                    .foregroundStyle(Color.labRed.opacity(0.85))
            }

            if model.dateBackEnabled && model.dateBackAvailable {
                HStack {
                    Text(String(localized: "日期"))
                        .font(.footnote)
                    Spacer()
                    DatePicker("", selection: Binding(
                        get: { model.dateStampDate },
                        set: { model.setDateStampDate($0) }), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }

                HStack {
                    Text(model.dateStampText)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.labCream)
                    Spacer()
                    Text(String(localized: "负片曝光"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Picker(String(localized: "字面"), selection: Binding(
                    get: { model.dateBackStyle },
                    set: { model.setDateBackStyle($0) })) {
                    ForEach(DateBackStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Picker(String(localized: "位置"), selection: Binding(
                    get: { model.dateBackPlacement },
                    set: { model.setDateBackPlacement($0) })) {
                    ForEach(DateBackPlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.filmBorderEnabled)

                if !model.filmBorderEnabled {
                    Text(String(localized: "打开片边后才能把日期放在帧与帧之间；当前会曝在画面内。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Picker(String(localized: "角落"), selection: Binding(
                    get: { model.dateBackCorner },
                    set: { model.setDateBackCorner($0) })) {
                    ForEach(DateBackCorner.allCases) { corner in
                        Text(corner.title).tag(corner)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "拍摄数据"))
                        .font(.footnote)
                    TextField("1/125  F2.8  ISO 400  50mm", text: $dataDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .padding(10)
                        .background(Color.white.opacity(0.055),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(String(localized: "120 会印在片边留白，135 会印在齿孔之间；日期仍按上面的字面曝光。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .effectCard()
        .opacity(model.dateBackAvailable ? 1 : 0.82)
    }

    private func gateChip(id: String, title: String, detail: String) -> some View {
        let selected = model.overscanFormat == id
        return Button {
            model.setOverscanFormat(id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Color.labCream : Color.secondary)
                Text(detail)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(selected ? Color.labRed : Color.secondary.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(selected ? Color.labRed.opacity(0.14) : Color.white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Color.labRed.opacity(0.6) : Color.white.opacity(0.08),
                            lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func effectCard() -> some View {
        padding(14)
            .background(Color.white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.075), lineWidth: 1)
            }
    }
}

/// The uncropped photograph handed to the crop screen.
struct CropImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// The tile for no film: the camera's 无胶卷 roll, or the editor's 无胶片.
struct NoFilmTile: View {
    let title: String
    let detail: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "circle.slash")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(on ? Color.labRed : .secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.labCream)
            .padding(.horizontal, 5)
            .frame(width: 168, height: 58)
            .background(on ? Color.labRed.opacity(0.12) : Color.white.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(on ? Color.labRed.opacity(0.55) : Color.white.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Every film (or paper) at once, grouped by kind, so a choice needs no long scroll.
struct StockBrowser: View {
    @ObservedObject var model: ViewModel
    let papers: Bool
    /// The camera's roll: which film is current, and where a pick goes (instead of the editor's).
    var current: String? = nil
    var pickFilm: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: SavedRecipe?
    @State private var newName = ""
    @AppStorage(Stock.orderKey) private var stockOrder = "kind"

    private var sections: [(String, [Stock])] {
        // By kind (default) or by maker — the 排列 button; `stockOrder` makes this view redraw when it changes.
        _ = stockOrder
        if papers { return Stock.grouped(model.papers) }
        let favourites = model.films.filter { model.favoriteFilms.contains($0.id) }
        return ([(String(localized: "收藏"), favourites)] + Stock.grouped(model.films)).filter { !$0.1.isEmpty }
    }

    /// A saved look: in the camera it becomes the roll, in the editor it goes on the photo.
    private func recipeTile(_ saved: SavedRecipe) -> some View {
        let on = current == saved.roll
        return Button {
            if let pickFilm { pickFilm(saved.roll) } else { model.applySavedRecipe(saved) }
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(saved.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text(model.filmName(for: saved.recipe.filmID)).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(on ? Color.labRed : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.labCream)
            .padding(.horizontal, 5)
            .frame(width: 168, height: 58)
            .background(on ? Color.labRed.opacity(0.12) : Color.white.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(on ? Color.labRed.opacity(0.55) : Color.white.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { newName = saved.name; renaming = saved } label: { Label(String(localized: "重命名"), systemImage: "pencil") }
            Button(role: .destructive) { model.deleteRecipe(saved.id) } label: { Label(String(localized: "删除配方"), systemImage: "trash") }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Not lazy: a LazyVGrid with pinned headers jumped while scrolling back up.
                TileFlow(spacing: 8) {
                    // The camera's roll can also be no film at all; so can the photo in the editor.
                    if !papers {
                        let plain = pickFilm != nil ? current?.isEmpty == true : model.recipe.noFilm == true
                        NoFilmTile(title: pickFilm != nil ? String(localized: "无胶卷") : String(localized: "无胶片"),
                                   detail: pickFilm != nil ? String(localized: "原始文件直接存进“照片”") : String(localized: "原图，不经过胶片"), on: plain) {
                            if let pickFilm { pickFilm("") } else { model.chooseNoFilm() }
                            dismiss()
                        }
                        .padding(.top, 8)
                    }
                    if !papers && !model.savedRecipes.isEmpty {
                        Text(String(localized: "我的配方 · \(model.savedRecipes.count)"))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .layoutValue(key: FullRow.self, value: true)
                        ForEach(model.savedRecipes) { saved in recipeTile(saved) }
                    }
                    ForEach(sections, id: \.0) { title, stocks in
                            Text("\(title) · \(stocks.count)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .layoutValue(key: FullRow.self, value: true)
                            ForEach(stocks) { stock in
                                let selected = stock.id == (current ?? (papers ? model.printStock
                                    : model.recipe.noFilm == true ? "" : model.filmStock))
                                let usable = !papers || model.canPrint(on: stock.id)
                                StockTile(stock: stock, selected: selected,
                                          recommended: papers && StockCatalog.recommendedPapers(for: model.filmStock).contains(stock.id)) {
                                    if let pickFilm { pickFilm(stock.id) }
                                    else if papers { model.paperChanged(stock.id) } else { model.filmChanged(stock.id) }
                                    dismiss()
                                }
                                .disabled(!usable)
                                .opacity(usable ? 1 : 0.32)
                                .overlay(alignment: .bottomTrailing) {
                                    if !papers && model.favoriteFilms.contains(stock.id) {
                                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.labRed).padding(6)
                                    }
                                }
                                .contextMenu {
                                    if !papers {
                                        let fav = model.favoriteFilms.contains(stock.id)
                                        Button { model.toggleFavoriteFilm(stock.id) } label: {
                                            Label(fav ? String(localized: "取消收藏") : String(localized: "收藏"), systemImage: fav ? "star.slash" : "star")
                                        }
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, 14)
            }
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle(pickFilm != nil ? String(localized: "装哪一卷") : papers ? String(localized: "相纸") : String(localized: "胶片"))
            .alert(String(localized: "重命名配方"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(String(localized: "名字"), text: $newName)
                Button(String(localized: "取消"), role: .cancel) { renaming = nil }
                Button(String(localized: "好")) { if let r = renaming { model.renameRecipe(r.id, to: newName) }; renaming = nil }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker(String(localized: "排列"), selection: $stockOrder) {
                            Text(String(localized: "按类型")).tag("kind")
                            Text(String(localized: "按品牌")).tag("brand")
                        }
                    } label: {
                        Label(stockOrder == "kind" ? String(localized: "按类型") : String(localized: "按品牌"), systemImage: "arrow.up.arrow.down")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .tint(Color.labRed)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.labInk)
    }
}

/// A view that takes a row of its own in `TileFlow` (a section header).
struct FullRow: LayoutValueKey { static let defaultValue = false }

/// Tiles left to right, wrapping; a `FullRow` view takes the whole row.
/// shortcut: lays out every tile at once, fine for the ~100 stocks there are.
struct TileFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        return CGSize(width: width, height: place(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let spots = place(subviews, width: bounds.width).spots
        for (v, r) in zip(subviews, spots) {
            v.place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY), proposal: ProposedViewSize(r.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> (spots: [CGRect], height: CGFloat) {
        var spots: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            var size = v.sizeThatFits(.unspecified)
            let wide = v[FullRow.self]
            if wide { size = v.sizeThatFits(ProposedViewSize(width: width, height: nil)); size.width = width }
            if x > 0 && (wide || x + size.width > width) { x = 0; y += row + spacing; row = 0 }
            spots.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            row = max(row, size.height)
            if wide { x = 0; y += row + spacing; row = 0 } else { x += size.width + spacing }
        }
        return (spots, y + row)
    }
}

/// Which stocks the browse-all grid shows.
struct BrowseStocks: Identifiable {
    let papers: Bool
    var id: Bool { papers }
}

/// The editor's histogram: red, green and blue over a dark plate, added where they overlap (white where all three are).
struct HistogramPlot: View {
    let channels: [[Float]]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7), with: .color(.black.opacity(0.5)))
            ctx.blendMode = .plusLighter
            let colours: [Color] = [Color(red: 1, green: 0.25, blue: 0.25), Color(red: 0.3, green: 1, blue: 0.35),
                                    Color(red: 0.3, green: 0.5, blue: 1)]
            for (c, bins) in channels.enumerated() where bins.count > 1 {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(bins.count - 1),
                                          y: size.height * (1 - CGFloat(v) * 0.92)))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(colours[c].opacity(0.55)))
            }
        }
        .accessibilityLabel(String(localized: "直方图"))
    }
}
