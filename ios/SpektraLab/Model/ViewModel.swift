//  ViewModel.swift — the app's state, and the loop that drives the engine.
//
//  One `ObservableObject` holds the whole app: the frame, the stocks, the
//  parameters, the rendered texture, and the errors. SwiftUI reads it; the
//  engine is driven from it.
//
//  **The render loop is the interesting part.** A slider drag must not queue
//  a hundred renders: the engine would work through them all after the finger
//  is already up, and the user would watch the preview lag behind their own
//  hand. So a change marks the render *stale*, and a render runs only when
//  the user stops moving — with one render in flight at a time, and a newer
//  request replacing an older one rather than queueing behind it.

import Foundation
import SwiftUI
import Metal
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ImageIO
import CoreImage
import Combine

@MainActor
final class ViewModel: ObservableObject {

    // MARK: - what the app shows

    /// The app's state.
    ///
    /// Named `AppState` rather than `State`: inside a SwiftUI view, `State`
    /// is SwiftUI's own property-wrapper type, and a nested type of the same
    /// name makes every `.failed` in the file ambiguous -- the compiler
    /// resolves it to some other `State` in scope and reports a type error
    /// about a gesture phase, which is nowhere near the problem.
    enum AppState: Equatable {
        case empty
        case importing
        case rendering
        case ready
        case failed(String)
    }

    @Published private(set) var state: AppState = .empty {
        didSet {
            if state != oldValue { NSLog("SpektraLab state: %@ -> %@", "\(oldValue)", "\(state)") }
        }
    }
    @Published private(set) var statusText = ""
    @Published private(set) var renderedTexture: MTLTexture?

    /// What identifies the current render.
    ///
    /// The engine gives every render a progress id, and it is a new string
    /// each time -- so it is what tells SwiftUI that the picture changed.
    /// The texture itself cannot: `MTLTexture` is not `Hashable`, and its
    /// `hashValue` does not exist.
    @Published private(set) var renderIdentity: String = ""
    @Published private(set) var lastRenderMs: Double = 0
    @Published private(set) var sourceSize: CGSize = .zero

    // MARK: - the look (single source of truth)

    /// The look on the canvas. Every control reads it and writes it through `edit`, which decides
    /// what the change costs: a reopen (stocks), a reload (the film gate), the 后期 pass alone, or a
    /// parameter update. Adding a control is a field on `PhotoRecipe`, its wire in `engineDelta`,
    /// and a binding through `edit` — nothing here.
    @Published private(set) var recipe = PhotoRecipe.standard

    /// Named looks (Model/RecipeLibrary.swift) and the films starred in pickers.
    @Published var savedRecipes: [SavedRecipe] = []
    @Published var favoriteFilms: [String] = []

    /// Change the look. Ignored while an export holds the engine.
    func edit(_ change: (inout PhotoRecipe) -> Void) {
        guard !exporting else { return }
        var next = recipe
        change(&next)
        next = normalized(next)
        guard next != recipe else { return }
        let before = recipe
        recipe = next
        respond(from: before, to: next)
    }

    /// The cheapest work that brings the canvas to the new look.
    private func respond(from a: PhotoRecipe, to b: PhotoRecipe) {
        if a.noFilm != b.noFilm || a.sceneBalance != b.sceneBalance {
            reloadPreviewForFilmEffect()     // the film edge may have gone with it: decode the frame again
            return
        }
        if a.filmStock != b.filmStock || a.printStock != b.printStock {
            reopenAndRender()
            return
        }
        let gateMoved = a.filmBorderEnabled != b.filmBorderEnabled
            || (b.filmBorderEnabled && (a.overscanFormat != b.overscanFormat || a.stripOrientation != b.stripOrientation))
        if gateMoved {
            reloadPreviewForFilmEffect()
            return
        }
        var onlyMarks = a
        onlyMarks.watermarks = b.watermarks
        if onlyMarks == b { return }            // drawn over the canvas (`WatermarkOverlay`); the print is the same
        var onlyHDR = a
        onlyHDR.hdr = b.hdr
        if onlyHDR == b {
            // A slide's HDR changes its develop (the stretch): render again; the render refreshes the HDR.
            if catalog.stock(b.filmStock)?.type == .positive { paramsDirty = true; scheduleRender() } else { refreshHDR() }
            return
        }
        var onlyFinish = a
        onlyFinish.adjustments = b.adjustments
        onlyFinish.hdr = b.hdr
        if onlyFinish == b {
            runLayer2()
            refreshHDR()
            return
        }
        paramsDirty = true
        scheduleRender()
    }

    /// One spelling for every look: defaults stored as nil (so undo and "edited" compare equal looks
    /// as equal), and the stock and gate rules held.
    private func normalized(_ input: PhotoRecipe) -> PhotoRecipe {
        var r = input
        r.params = r.normalizedParams
        if !films.isEmpty, !films.contains(where: { $0.id == r.filmStock }) { r.filmStock = StockCatalog.defaultFilm }
        if !papers.isEmpty, !papers.contains(where: { $0.id == r.printStock }) { r.printStock = StockCatalog.defaultPaper }
        // A black-and-white film prints on its silver paper, a colour one on colour paper.
        if !catalog.canPrint(film: r.filmStock, on: r.printStock), let own = catalog.ownPaper(of: r.filmStock) {
            r.printStock = own
        }
        if r.overscanFormat != FilmGateCatalog.automaticID, FilmGateCatalog.gate(id: r.overscanFormat) == nil {
            r.overscanFormat = FilmGateCatalog.automaticID
        }
        let gate = FilmGateCatalog.resolve(selection: r.overscanFormat, imageAspect: naturalAspect)
        if gate.isSquare { r.stripOrientation = FilmStripOrientation.automatic.rawValue }
        if !gate.supportsDateBack {
            r.dateBackEnabled = false
            r.dateBackPlacement = DateBackPlacement.frame.rawValue
        }
        if !r.filmBorderEnabled, r.dateBackPlacement == DateBackPlacement.rebate.rawValue {
            r.dateBackPlacement = DateBackPlacement.frame.rawValue
        }
        if r.adjustments?.isNeutral == true { r.adjustments = nil }
        if r.paperGrade == PaperGrade.standard { r.paperGrade = nil }
        if r.edgeText?.isEmpty == true { r.edgeText = nil }
        if r.antihalationRemoved == false { r.antihalationRemoved = nil }
        // 均衡 chosen stays "balanced": nil means an older photo that never chose (it develops balanced, but a new
        // photo inheriting "上次使用" takes 保高光 from it, not 均衡 — `newPhotoRecipe`).
        if r.lensFilter?.isEmpty == true { r.lensFilter = nil }
        if r.filmFormatMM == 36 { r.filmFormatMM = nil }
        if r.sceneCurve?.isIdentity == true { r.sceneCurve = nil }
        if r.leakKind?.isEmpty == true || r.leakKind == "off" { r.leakKind = nil }
        if r.leakAmount == 1 { r.leakAmount = nil }
        if (r.leakEdge ?? 0) <= 0 { r.leakEdge = nil }
        if r.leakSeed == 0 { r.leakSeed = nil }
        if r.watermarks?.isEmpty == true { r.watermarks = nil }
        if let g = r.sceneBalance, g.count != 3 || g.allSatisfy({ abs($0 - 1) < 1e-6 }) { r.sceneBalance = nil }
        if r.diffusionFamily?.isEmpty == true { r.diffusionFamily = nil }
        if r.diffusionStrength == 0.5 { r.diffusionStrength = nil }
        if r.lensCharacter?.isEmpty == true { r.lensCharacter = nil }
        if r.lensAmount == 1 { r.lensAmount = nil }
        if r.noFilm == true {
            r.hdr = nil                     // no film, no film highlights to lift
            r.filmBorderEnabled = false     // nor a film edge
            if r.dateBackPlacement == DateBackPlacement.rebate.rawValue { r.dateBackPlacement = DateBackPlacement.frame.rawValue }
        } else { r.noFilm = nil }
        return r
    }

    // Read-only views of the recipe, in the shapes the controls want.
    var params: [String: Double] { recipe.params }
    var filmStock: String { recipe.filmStock }
    var printStock: String { recipe.printStock }
    var adjustments: Adjustments { recipe.adjustments ?? Adjustments() }
    var paperGrade: String { recipe.paperGrade ?? PaperGrade.standard }
    var edgeText: String { recipe.edgeText ?? "" }
    var antihalationRemoved: Bool { recipe.antihalationRemoved ?? false }
    var exposureMethod: String { recipe.exposureMethod ?? "balanced" }
    var lensFilter: String { recipe.lensFilter ?? "" }
    var filmFormatMM: Double { recipe.filmFormatMM ?? 36 }
    var sceneCurve: CurveSet { recipe.sceneCurve ?? CurveSet() }
    var leakKind: String { recipe.leakKind ?? "" }
    var leakAmount: Double { recipe.leakAmount ?? 1 }
    var diffusionFamily: String { recipe.diffusionFamily ?? "" }
    var diffusionStrength: Double { recipe.diffusionStrength ?? 0.5 }
    var lensCharacter: String { recipe.lensCharacter ?? "" }
    var lensAmount: Double { recipe.lensAmount ?? 1 }
    var filmBorderEnabled: Bool { recipe.filmBorderEnabled }
    var overscanFormat: String { recipe.overscanFormat }
    var stripOrientation: FilmStripOrientation { FilmStripOrientation(rawValue: recipe.stripOrientation) ?? .automatic }
    var dateBackEnabled: Bool { recipe.dateBackEnabled }
    var dateBackStyle: DateBackStyle { DateBackStyle(rawValue: recipe.dateBackStyle) ?? .lcd }
    var dateBackPlacement: DateBackPlacement { DateBackPlacement(rawValue: recipe.dateBackPlacement) ?? .frame }
    var dateBackCorner: DateBackCorner { DateBackCorner(rawValue: recipe.dateBackCorner) ?? .br }

    /// A black-and-white film printed on a silver paper: the grade applies.
    var isSilverPrint: Bool { catalog.isMonochrome(filmStock) && catalog.isMonochrome(printStock) }

    func canPrint(on paper: String) -> Bool { catalog.canPrint(film: filmStock, on: paper) }

    // The controls' setters, each one `edit`. Kept so the pages read as before.
    func parameterChanged(_ key: String, _ value: Double) { edit { $0.params[key] = value } }
    func setAdjustments(_ a: Adjustments) { edit { $0.adjustments = a } }
    func setPaperGrade(_ g: String) { edit { $0.paperGrade = g } }
    func setEdgeText(_ t: String) { edit { $0.edgeText = String(t.trimmingCharacters(in: .whitespaces).prefix(24)) } }
    func setAntihalationRemoved(_ on: Bool) { edit { $0.antihalationRemoved = on } }
    func setHDREnabled(_ on: Bool) { edit { $0.hdr = on ? true : nil } }
    func setExposureMethod(_ m: String) { edit { $0.exposureMethod = m } }
    func setLensFilter(_ f: String) { edit { $0.lensFilter = f } }
    func setFilmFormat(_ mm: Double) { edit { $0.filmFormatMM = mm } }
    func setSceneCurve(_ c: CurveSet) { edit { $0.sceneCurve = c } }
    func setLeak(kind: String? = nil, amount: Double? = nil, edge: Double? = nil) {
        edit { r in
            if let kind { r.leakKind = kind }
            if let amount { r.leakAmount = amount }
            if let edge { r.leakEdge = edge }
        }
    }
    /// 随机: a new place and shape for this photo's leak (never the one it has); `false` goes back to the body's.
    func shuffleLeak(_ on: Bool = true) {
        edit { r in
            guard on else { r.leakSeed = nil; return }
            var next = r.leakSeed ?? 0
            while next == (r.leakSeed ?? 0) { next = Int.random(in: 1...Int(Int32.max)) }
            r.leakSeed = next
        }
    }
    func setDiffusion(family: String? = nil, strength: Double? = nil) {
        edit { r in
            if let family { r.diffusionFamily = family }
            if let strength { r.diffusionStrength = strength }
        }
    }
    func setLens(character: String? = nil, amount: Double? = nil) {
        edit { r in
            if let character { r.lensCharacter = character }
            if let amount { r.lensAmount = amount }
        }
    }

    /// Crop and straighten of the photograph being edited.
    @Published private(set) var crop = FrameCrop()

    /// Undo / redo over everything the editor changes (the look and the crop).
    /// A burst of changes (a slider drag) settles into one step after a pause.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private struct EditSnapshot: Equatable {
        var recipe: PhotoRecipe
        var crop: FrameCrop
    }
    private var undoStack: [EditSnapshot] = [] { didSet { canUndo = !undoStack.isEmpty } }
    private var redoStack: [EditSnapshot] = [] { didSet { canRedo = !redoStack.isEmpty } }
    /// The state the last step ended in; nil outside the editor.
    private var settled: EditSnapshot?
    private var settleTask: Task<Void, Never>?
    private var historyWatch: AnyCancellable?

    /// Hold-to-compare: the imported photograph itself, before film and 后期.
    @Published private(set) var showingOriginal = false
    private var originalTexture: MTLTexture?
    /// What the canvas goes back to when the compare button is released.
    private var printTexture: MTLTexture?
    /// The last engine preview, kept while Layer 2 is active so a slider only
    /// re-runs the pass.
    private var layer2Source: Layer2Source?
    private var layer2Pending = false
    private var layer2Running = false

    /// The date back's date and data line: the photograph's, not the look's.
    @Published private(set) var dateStampDate = Date()
    @Published private(set) var shootingDataText = "1/125  F2.8  ISO 400  50mm"

    /// The catalogue, read at launch.
    @Published private(set) var catalog = StockCatalog(films: [], papers: [], slides: [], grades: [])

    // MARK: - the photo wall

    /// Every imported photograph, newest first. The originals and thumbnails
    /// live on disk; this array is the UI's index into them.
    @Published private(set) var library: [LibraryPhoto] = []
    /// Non-nil while the wall is showing and a photograph should be open in
    /// the editor. `ContentView` switches the whole screen on this.
    @Published private(set) var editingPhotoID: UUID?
    /// A modal, wall-level operation: importing, opening, or applying a recipe
    /// across a selection. It is separate from `state`, which belongs to the
    /// editor's engine session.
    @Published private(set) var libraryBusy: String?
    @Published var libraryMessage: String?
    /// Files picked again that were all imported before: the wall asks whether to import them anyway.
    @Published var reimportOffer: ReimportOffer?
    struct ReimportOffer: Identifiable { let id = UUID(); let urls: [URL]; let count: Int }
    /// The last copied look. Kept in UserDefaults as well as memory, so
    /// closing the app does not lose a recipe the person just copied.
    @Published private(set) var clipboardRecipe: PhotoRecipe?
    /// The photograph the clipboard recipe came from. It is deliberately not a
    /// valid paste target: a recipe is copied *from* this frame, not back onto
    /// it, and the wall dims it while the recipe is on the clipboard.
    @Published private(set) var recipeSourcePhotoID: UUID?

    var editingPhoto: LibraryPhoto? {
        guard let id = editingPhotoID else { return nil }
        return library.first { $0.id == id }
    }

    /// The stocks, in the order the scrolling strip shows them.
    /// Films and papers by maker, then by name (upstream 2.4.1's `brandOrder`): every picker reads these.
    var films: [Stock] { Stock.brandOrdered(catalog.films + catalog.slides) }
    var papers: [Stock] { Stock.brandOrdered(catalog.papers) }

    /// The editor's name for the look: "无胶片" or the film.
    var currentLookName: String { recipe.noFilm == true ? "无胶片" : currentFilmName }

    var currentFilmName: String {
        films.first { $0.id == filmStock }?.name ?? filmStock
    }

    var currentPaperName: String {
        papers.first { $0.id == printStock }?.name ?? printStock
    }

    var selectedGate: FilmGate {
        FilmGateCatalog.resolve(selection: overscanFormat, imageAspect: naturalAspect)
    }

    /// The crop shape handed to the engine. The engine reads the strip's
    /// direction from this shape, so changing it here changes the real
    /// perforations and rebate, not just the SwiftUI frame.
    var filmCropAspect: CGFloat {
        stripOrientation.targetAspect(for: selectedGate, sourceAspect: naturalAspect)
    }

    var gateDisplayName: String {
        overscanFormat == FilmGateCatalog.automaticID
            ? "自动 · \(selectedGate.title)"
            : selectedGate.title
    }

    var filmEdgeDisplayName: String {
        guard filmBorderEnabled else { return "关闭" }
        return stripOrientation == .automatic
            ? gateDisplayName
            : "\(gateDisplayName) · \(stripOrientation.title)"
    }

    var stripOrientationAvailable: Bool { !selectedGate.isSquare }

    var dateBackAvailable: Bool { selectedGate.supportsDateBack }

    var dateStampText: String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day], from: dateStampDate)
        return String(format: "'%02d %02d %02d",
                      (parts.year ?? 2000) % 100,
                      parts.month ?? 1,
                      parts.day ?? 1)
    }

    /// A rebate date needs the film edge around the gate. Without it the
    /// engine prints the date in the picture instead.
    var effectiveDateBackPlacement: DateBackPlacement {
        filmBorderEnabled ? dateBackPlacement : .frame
    }

    /// Enough state to diagnose an engine failure without a debugger.
    var diagnostics: String {
        let root = engine?.resources.path ?? SpektraEngine.defaultResources().path
        return [
            "state: \(state)",
            "profiles: \(catalog.films.count) films / \(catalog.slides.count) slides / \(catalog.papers.count) papers",
            "resources: \(root)",
            "engine: \(engine == nil ? "not started" : "ready")",
            "film edge: \(filmBorderEnabled ? "on" : "off") · \(gateDisplayName) · \(stripOrientation.detail) · crop \(String(format: "%.4f", filmCropAspect))",
            "status: \(statusText)"
        ].joined(separator: "\n")
    }

    /// The picked photo, kept so it can be re-decoded at full size for export.
    private var pickedItem: PhotosPickerItem?
    private var originalTypeHint: UTType?
    /// Original bytes for the full-resolution export; a preview-only
    /// transferable must never replace them.
    private var originalData: Data?

    /// The decoded frame in the engine's input space.
    private var frame: DecodedFrame?
    /// The photograph's own long/short ratio, before a film gate crops it.
    private var naturalAspect: CGFloat = 3.0 / 2.0
    /// Gate and orientation changes re-decode the photograph. Coalesce them so
    /// a slow, older decode can never finish last and restore the previous
    /// direction after the user has picked a new one.
    private var effectReloadNeeded = false
    private var effectReloadRunning = false
    private var sourceGeneration = 0

    // MARK: - the engine

    private var engine: SpektraEngine?
    /// The canvas renderer. The view needs it to draw the texture.
    private(set) var renderer: CanvasRenderer? = nil
    private var device: MTLDevice?

    /// The render loop's state.
    private var renderTask: Task<Void, Never>?
    private var renderInFlight = false
    private var needsRender = false
    private var paramsDirty = false
    /// The recipe the editor opened with. `closeEditor` compares against it so
    /// merely viewing a photo does not mark it as edited.
    private var editingBaseRecipe: PhotoRecipe?

    // MARK: - life cycle

    init() {
        historyWatch = objectWillChange.sink { [weak self] _ in self?.scheduleSettle() }
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .failed("这台设备没有可用的 Metal 设备")
            return
        }
        self.device = device

        // The catalogue and the defaults, before the engine: a stock list that
        // depends on the engine's resources is a stock list that is empty when
        // the resources are missing, and an empty list is harder to diagnose
        // than an error.
        let resources = SpektraEngine.defaultResources()
        catalog = StockCatalog.load(resources: resources)
        loadLibrary()
        loadClipboardRecipe()
        loadSavedRecipes()


        do {
            let engine = try SpektraEngine(device: device, resources: resources)
            self.engine = engine
            self.renderer = CanvasRenderer(device: device)
            state = .empty
            statusText = "就绪 · \(catalog.films.count) 款胶片 · \(catalog.papers.count) 款相纸"
        } catch {
            // The CI build does not ship the resource archive inside the .app:
            // a 15 MB payload makes the side-loading installer fail when it
            // copies the unpacked IPA to its fixed `App.app`, and it reports
            // only "Failed to get bundle ID". The six-entry test bundle
            // installed fine, so the archive is fetched here once instead.
            state = .importing
            statusText = "首次启动：正在准备引擎资源…"
            Task { @MainActor in
                await self.prepareResourcesAndStart(device: device)
            }
        }
    }

    /// First-launch path: download the resources, unpack them, start the
    /// engine. Every launch after that finds the unpacked copy in Caches and
    /// never reaches the network.
    private func prepareResourcesAndStart(device: MTLDevice) async {
        do {
            let resources = try await SpektraEngine.fetchResourcesRemotely()
            catalog = StockCatalog.load(resources: resources)
            let engine = try SpektraEngine(device: device, resources: resources)
            self.engine = engine
            self.renderer = CanvasRenderer(device: device)
            state = .empty
            statusText = "就绪 · \(catalog.films.count) 款胶片 · \(catalog.papers.count) 款相纸"
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "资源准备失败"
        }
    }

    /// Puts the previous run's crash on screen, so it does not take another
    /// cycle of "it just closes" to find out what happened.
    private func reportPreviousCrash() {
        guard let crash = CrashLog.take() else { return }
        state = .failed("上次异常退出：\(crash)")
        statusText = "上次异常退出 · \(crash)"
    }

    // MARK: - importing

    /// Load original bytes, preferring a RAW representation when the picker
    /// exposes one. Plain `Data.self` is re-encoded by Photos for RAW assets.
    private static func loadData(from item: PhotosPickerItem) async throws -> Data {
        if let raw = try? await item.loadTransferable(type: PickedImageData.self)?.data,
           !raw.isEmpty {
            return raw
        }
        return try await item.loadTransferable(type: Data.self) ?? Data()
    }

    /// Import several photographs from Photos. Importing only fills the wall;
    /// it does not steal the screen by opening the first one.
    func importPickedItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        // A photo picked from Photos is linked, not copied: its original stays the one in Photos.
        // Without library access (or without an identifier) it is copied as before.
        let canLink = await PhotoAssets.authorize()
        libraryBusy = "正在导入 0/\(items.count)"
        var imported = 0
        var failed = 0
        for (index, item) in items.enumerated() {
            libraryBusy = "正在导入 \(index + 1)/\(items.count)"
            if canLink, let id = item.itemIdentifier, PhotoAssets.asset(id) != nil {
                if await linkAsset(id) != nil { imported += 1 } else { failed += 1 }
                continue
            }
            do {
                let data = try await Self.loadData(from: item)
                guard !data.isEmpty else { throw DecodeError.unreadable("照片没有返回数据") }
                let hint = item.supportedContentTypes.first { $0.conforms(to: .rawImage) }
                    ?? item.supportedContentTypes.first
                    ?? ImageDecoder.inferredRAWTypeHint(for: data)
                let name = String(format: "照片 %02d", library.count + 1)
                try await addPhoto(data: data, name: name, typeHint: hint)
                imported += 1
            } catch {
                failed += 1
            }
            await Task.yield()
        }
        await developImportThumbnails()
        libraryMessage = failed == 0
            ? "已导入 \(imported) 张照片"
            : "已导入 \(imported) 张，\(failed) 张无法读取"
    }

    /// Import one or more files, including the RAW containers Photos may only
    /// expose as a rendered preview.
    /// Files and folders from the Files app, a memory card or another app. A folder is read through (a card's
    /// DCIM and its subfolders); of a RAW + JPEG pair only the RAW comes in; a file imported before (same name,
    /// size and date) is skipped, so a card can be imported again and only its new frames arrive.
    func importFiles(from urls: [URL], again: Bool = false) async {
        guard !urls.isEmpty else { return }
        var scoped: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() { scoped.append(url) }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }

        let keys: [URLResourceKey] = [.isDirectoryKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey]
        func picture(_ u: URL) -> Bool { RAWTypes.isPicture(u) }
        var files: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let u = walk?.nextObject() as? URL { if picture(u) { files.append(u) } }
            } else {
                files.append(url)
            }
        }
        // RAW + JPEG from one exposure: the RAW is the negative.
        func isRAW(_ u: URL) -> Bool { RAWTypes.hint(forExtension: u.pathExtension)?.conforms(to: .rawImage) ?? false }
        let rawStems = Set(files.filter(isRAW).map { $0.deletingPathExtension().path.lowercased() })
        files = files.filter { isRAW($0) || !rawStems.contains($0.deletingPathExtension().path.lowercased()) }
        files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let present = Set(library.compactMap(\.importedFrom))
        func identity(_ u: URL) -> String {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(u.lastPathComponent)|\(v?.fileSize ?? 0)|\(Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        }
        let fresh = again ? files : files.filter { !present.contains(identity($0)) }
        let skipped = files.count - fresh.count
        guard !fresh.isEmpty else {
            if files.isEmpty { libraryMessage = "没有找到照片或 RAW 文件" } else { reimportOffer = ReimportOffer(urls: urls, count: skipped) }
            return
        }
        libraryBusy = "正在导入 0/\(fresh.count)"
        var imported = 0
        var failures: [String] = []
        for (index, url) in fresh.enumerated() {
            libraryBusy = "正在导入 \(index + 1)/\(fresh.count)"
            NSLog("SpektraLab import: %d/%d %@", index + 1, fresh.count, url.lastPathComponent)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard !data.isEmpty else { throw DecodeError.unreadable("文件为空") }
                let hint = RAWTypes.hint(forExtension: url.pathExtension)
                try await addPhoto(data: data,
                                   name: url.deletingPathExtension().lastPathComponent,
                                   typeHint: hint, importedFrom: identity(url))
                imported += 1
            } catch {
                failures.append("\(url.lastPathComponent)：\(Self.importFailureReason(error, url: url))")
            }
            await Task.yield()
        }
        await developImportThumbnails()
        var parts = ["已导入 \(imported) 张"]
        if skipped > 0 { parts.append("\(skipped) 张导入过，已跳过") }
        if !failures.isEmpty {
            importFailures = ImportFailures(summary: parts.joined(separator: "，"), lines: failures)
        } else {
            libraryMessage = parts.joined(separator: "，")
        }
    }

    /// Files that did not come in, one line each (name: why), shown in an alert after the import.
    @Published var importFailures: ImportFailures?
    struct ImportFailures: Identifiable { let id = UUID(); let summary: String; let lines: [String] }

    /// Why a file did not import, in a few words.
    private static func importFailureReason(_ error: Error, url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "x3f": return "Sigma Foveon RAW 暂不支持"
        case "gpr": return "GoPro GPR RAW 暂不支持"
        default: break
        }
        let text = error.localizedDescription
        if text.contains("Unsupported") { return "这种 RAW 格式读不了" }
        if text.contains("文件为空") { return "文件是空的" }
        return "无法读取"
    }

    /// The old "imported before" list (name|size|mtime), read once by `adoptLegacyImportList`.
    static let importedSourcesKey = "SpektraLab.importedSources"

    /// Single-file compatibility entry point for the DEBUG probe.
    func importFile(from url: URL) async {
        await importFiles(from: [url])
    }

    /// Put the bytes on disk, make the wall's thumbnail, and append the photo.
    @discardableResult
    private func addPhoto(data: Data, name: String, typeHint: UTType?, importedFrom: String? = nil) async throws -> UUID {
        let root = libraryRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let ext = typeHint?.preferredFilenameExtension ?? "img"
        let fileName = "\(id.uuidString).\(ext)"
        let originalURL = root.appendingPathComponent(fileName)
        try data.write(to: originalURL, options: .atomic)

        let made = LibraryThumbnail.from(data: data)
        NSLog("SpektraLab import: ImageIO thumbnail %@", made == nil ? "none" : "ok")
        let thumbnail = made?.0 ?? LibraryThumbnail.placeholder()
        var width = made?.1 ?? thumbnail.cgImage?.width ?? 0
        var height = made?.2 ?? thumbnail.cgImage?.height ?? 0
        var aspect = Double(thumbnail.size.width / max(thumbnail.size.height, 1))
        // A RAW ImageIO cannot read (LibRaw's formats): its shape from LibRaw, its thumbnail developed afterwards.
        // ImageIO's thumbnail of a RAW can be the file's own tiny preview (Mamiya MEF 192×144) or a black one
        // (Kodak DCR): those are developed after the import too.
        let poorThumbnail = made.map { t in
            max(t.0.size.width, t.0.size.height) < 600 || t.0.cgImage.map { ImageDecoder.isBlack(CIImage(cgImage: $0)) } == true
        } ?? true
        let needsDevelopedThumbnail = poorThumbnail && typeHint?.conforms(to: .rawImage) == true
        if needsDevelopedThumbnail {
            // Nothing here reads it either: refuse it rather than keep a photo that never opens.
            let frame: DecodedFrame
            do {
                frame = try await Task.detached(priority: .userInitiated, operation: {
                    try ImageDecoder.decode(data: data, maxLongEdge: 1200, typeHint: typeHint)
                }).value
            } catch {
                try? FileManager.default.removeItem(at: originalURL)
                NSLog("SpektraLab import: refused %@ — %@", name, error.localizedDescription)
                throw error
            }
            width = frame.width; height = frame.height
            aspect = Double(frame.width) / Double(max(frame.height, 1))
        }
        try LibraryThumbnail.saveJPEG(thumbnail, to: thumbnailURL(for: id))

        let photo = LibraryPhoto(id: id,
                                 name: name,
                                 fileName: fileName,
                                 typeIdentifier: typeHint?.identifier,
                                 pixelWidth: width,
                                 pixelHeight: height,
                                 sourceAspect: aspect,
                                 createdAt: Date(),
                                 recipe: newPhotoRecipe,
                                 frameNumber: CameraBody.takeFrame(),
                                 importedFrom: importedFrom,
                                 isEdited: false,
                                 thumbnail: thumbnail)
        library.insert(photo, at: 0)
        saveLibraryManifest()
        if needsDevelopedThumbnail { thumbnailsToDevelop.append(id) }
        return id
    }

    /// Decode and open one photograph in the editor's engine session. This is
    /// the old import path minus the library write: the photo already exists
    /// on the wall.
    private func loadPhoto(data: Data, typeHint: UTType?, name: String) async throws {
        sourceGeneration &+= 1
        effectReloadNeeded = false
        originalData = data
        originalTexture = nil
        originalTypeHint = typeHint
        let decoded = try ImageDecoder.decode(data: data,
                                              maxLongEdge: ImageDecoder.previewLongEdge,
                                              typeHint: typeHint).applying(crop).balanced(recipe.sceneBalance)
        naturalAspect = CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
        recipe = normalized(recipe)
        let framed = filmBorderEnabled
            ? decoded.centerCropped(toTargetAspect: filmCropAspect)
            : decoded
        try await loadFrame(framed)
        statusText = "已载入 \(name) · \(decoded.width)×\(decoded.height) · \(String(format: "%.1f", decoded.megapixels)) MP"
    }

    /// The look currently on the canvas, ready to be stored on a photo or
    /// copied to the wall's recipe clipboard.
    var currentRecipe: PhotoRecipe { recipe }

    /// Every path that opens a session uses the same complete delta. The
    /// stocks are not enough: the film edge and date back are exposure on the
    /// negative, so leaving them out here would make the preview and export
    /// disagree with the controls.
    private func currentEngineDelta() -> [String: ParamValue] {
        var delta = currentRecipe.engineDelta(filmName: currentFilmName,
                                  frameNumber: editingPhoto?.frameNumber ?? 12,
                                  imageAspect: naturalAspect,
                                  stamp: dateStampDate,
                                  shootingData: shootingDataText,
                                  cameraEV: editingPhoto?.cameraEV)
        // The live tier at the preview size the photo was decoded at (Settings › 预览尺寸).
        delta["preview_long_edge"] = .number(Double(ImageDecoder.previewLongEdge))
        // A slide with HDR on develops stretched, with one grain seed for both renditions (`HDRSlide`).
        for (k, v) in HDRSlide.sdrWire(on: isSlideHDR, seed: editingPhotoID?.hashValue ?? 1) { delta[k] = v }
        return delta
    }

    /// The delta for `spk_open` only. `product_defaults` selects the product's
    /// defaults at open time; `spk_set_params` does not accept the key, so it
    /// must not be part of `currentEngineDelta()`, which also feeds the live
    /// parameter updates.
    private func currentOpenDelta() -> [String: ParamValue] {
        var delta = currentEngineDelta()
        delta[ParamDefaults.productDefaultsKey] = .bool(true)
        return delta
    }

    // MARK: - the photo wall

    private static let clipboardRecipeKey = "SpektraLab.clipboardRecipe"
    private static let clipboardRecipeSourceKey = "SpektraLab.clipboardRecipeSource"

    var libraryRootURL: URL { libraryRoot }
    /// 水印's marks on disk.
    lazy var watermarkShelf = WatermarkShelf(root: libraryRoot)

    private var libraryRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SpektraLabLibrary", isDirectory: true)
    }

    func thumbnailURL(for id: UUID) -> URL {
        libraryRoot.appendingPathComponent("\(id.uuidString)-thumb.jpg")
    }

    /// The original's bytes: the file in the library folder, or the system Photos asset it reads in place.
    private func originalData(for photo: LibraryPhoto) async throws -> Data {
        if let assetID = photo.assetID {
            guard let asset = PhotoAssets.asset(assetID) else {
                throw DecodeError.unreadable("这张照片已经不在系统相册里了")
            }
            return try await PhotoAssets.originalData(asset).data
        }
        return try Data(contentsOf: originalURL(for: photo), options: [.mappedIfSafe])
    }

    /// Open a photo from the system library (linking it first if it has no SpektraLab entry yet).
    func openAsset(_ localIdentifier: String) async {
        guard libraryBusy == nil else { return }
        libraryBusy = "正在从相册读取…"
        let id = await linkAsset(localIdentifier)
        libraryBusy = nil
        if let id { await openLibraryPhoto(id) }
    }

    /// The SpektraLab entry of a system photo, made the first time it is needed: its look, crop and
    /// developed thumbnail — never a copy of the original. Nil when the photo is gone.
    func linkAsset(_ localIdentifier: String) async -> UUID? {
        if let linked = library.first(where: { $0.assetID == localIdentifier }) { return linked.id }
        guard let asset = PhotoAssets.asset(localIdentifier) else {
            libraryMessage = "这张照片已经不在系统相册里了"
            return nil
        }
        let resource = PhotoAssets.originalResource(asset)
        let thumbnail = await PhotoAssets.thumbnail(asset, side: LibraryThumbnail.maxPixel) ?? LibraryThumbnail.placeholder()
        let id = UUID()
        try? LibraryThumbnail.saveJPEG(thumbnail, to: thumbnailURL(for: id))
        let w = max(asset.pixelWidth, 1), h = max(asset.pixelHeight, 1)
        let name = resource.map { ($0.originalFilename as NSString).deletingPathExtension } ?? "相册照片"
        let photo = LibraryPhoto(id: id, name: name, fileName: "", typeIdentifier: resource?.uniformTypeIdentifier,
                                 pixelWidth: w, pixelHeight: h, sourceAspect: Double(w) / Double(h),
                                 createdAt: asset.creationDate ?? Date(), recipe: newPhotoRecipe,
                                 frameNumber: CameraBody.takeFrame(), assetID: localIdentifier,
                                 isEdited: false, thumbnail: thumbnail)
        library.insert(photo, at: 0)
        saveLibraryManifest()
        return id
    }

    /// Drop the entries of system photos that were deleted in Photos (their look and thumbnail).
    /// Only with full access: under limited access a photo outside the selection looks deleted.
    func pruneDeletedAssets() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        let linked = library.compactMap(\.assetID)
        guard !linked.isEmpty else { return }
        var alive = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: linked, options: nil).enumerateObjects { a, _, _ in
            alive.insert(a.localIdentifier)
        }
        let gone = Set(library.filter { $0.assetID.map { !alive.contains($0) } ?? false }.map(\.id))
            .subtracting(editingPhotoID.map { [$0] } ?? [])
        guard !gone.isEmpty else { return }
        for id in gone {
            try? FileManager.default.removeItem(at: thumbnailURL(for: id))
            try? FileManager.default.removeItem(at: largeDevelopURL(for: id))
        }
        if let source = recipeSourcePhotoID, gone.contains(source) {
            recipeSourcePhotoID = nil
            UserDefaults.standard.removeObject(forKey: Self.clipboardRecipeSourceKey)
        }
        library.removeAll { gone.contains($0.id) }
        saveLibraryManifest()
        NSLog("SpektraLab library: dropped %d photos deleted in Photos", gone.count)
    }

    // MARK: - negatives

    /// Days a shot's negative is kept once its print is in Photos; 0 keeps it for good.
    static let negativeKeepDaysKey = "SpektraLab.negativeKeepDays"
    static var negativeKeepDays: Int {
        UserDefaults.standard.object(forKey: negativeKeepDaysKey) as? Int ?? 7
    }

    /// Shots whose negative may go: taken with SpektraLab's camera, kept as a file here, and already
    /// exported to Photos — a shot never exported is never removed (it would be gone for good).
    func expendableNegatives(olderThanDays days: Int?) -> [LibraryPhoto] {
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        return library.filter { p in
            p.captured && p.assetID == nil && !p.fileName.isEmpty && p.exportedAt != nil && p.id != editingPhotoID
                && (cutoff.map { p.createdAt < $0 } ?? true)
        }
    }

    func negativeBytes(_ photos: [LibraryPhoto]) -> Int64 {
        photos.reduce(0) { $0 + Int64((try? originalURL(for: $1).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Remove expired negatives (on becoming active). Their prints stay in Photos. Shots never
    /// exported go only if the person chose an age for them (Settings › 未导出的照片).
    func pruneExpiredNegatives() {
        let days = Self.negativeKeepDays
        let old = days > 0 ? expendableNegatives(olderThanDays: days) : []
        let unexportedDays = Self.unexportedDeleteDays
        let forgotten = unexportedDays > 0 ? unexportedShots(olderThanDays: unexportedDays) : []
        guard !old.isEmpty || !forgotten.isEmpty else { return }
        NSLog("SpektraLab negatives: removing %d exported, %d never exported", old.count, forgotten.count)
        deletePhotos(Set((old + forgotten).map(\.id)))
        libraryMessage = forgotten.isEmpty
            ? "已清理 \(old.count) 张超过 \(days) 天、已导出的底片"
            : "已清理 \(old.count + forgotten.count) 张底片（其中 \(forgotten.count) 张超过 \(unexportedDays) 天未导出）"
    }

    // MARK: - culling

    /// Days after which never-exported shots are removed; 0 (the default) never.
    static let unexportedDeleteDaysKey = "SpektraLab.unexportedDeleteDays"
    static var unexportedDeleteDays: Int { UserDefaults.standard.integer(forKey: unexportedDeleteDaysKey) }
    static let cullSnoozeKey = "SpektraLab.cullSnoozeUntil"
    /// A shot is "waiting" once it is this many days old without an export.
    static let cullReminderDays = 3

    /// Shots from SpektraLab's camera never exported, newest first; `olderThanDays` 0 means all.
    func unexportedShots(olderThanDays days: Int = 0) -> [LibraryPhoto] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return library.filter { p in
            p.captured && p.exportedAt == nil && p.assetID == nil && !p.fileName.isEmpty
                && p.id != editingPhotoID && p.createdAt <= cutoff
        }
    }

    /// The wall's reminder: waiting shots and their size, nil when there are none or it is snoozed.
    var cullReminder: (count: Int, bytes: Int64, soon: Int)? {
        if let until = UserDefaults.standard.object(forKey: Self.cullSnoozeKey) as? Date, until > Date() { return nil }
        let waiting = unexportedShots(olderThanDays: Self.cullReminderDays)
        guard !waiting.isEmpty else { return nil }
        let days = Self.unexportedDeleteDays
        let soon = days > 0 ? unexportedShots(olderThanDays: days - 1).count : 0
        return (waiting.count, negativeBytes(waiting), soon)
    }

    func snoozeCullReminder() {
        UserDefaults.standard.set(Date().addingTimeInterval(7 * 86_400), forKey: Self.cullSnoozeKey)
        objectWillChange.send()
    }

    @Published private(set) var batchExporting = false

    // MARK: - developing shots as they are taken

    /// Shots waiting to be developed and exported, and whether one is under way.
    @Published private(set) var developPending = 0
    private var developQueue: [UUID] = []
    private var developRunning = false
    static let autoDevelopKey = "SpektraLab.autoDevelop"

    /// Develop this shot with its look and put the print in Photos, after the ones before it.
    func queueDevelop(_ id: UUID) {
        developQueue.append(id)
        developPending = developQueue.count + (developRunning ? 1 : 0)
        guard !developRunning else { return }
        developRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.developQueue.isEmpty {
                // One engine: wait for the editor, an export or a batch to be done with it.
                while self.editingPhotoID != nil || self.batchExporting || self.exporting {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                let id = self.developQueue.removeFirst()
                self.developPending = self.developQueue.count + 1
                NSLog("SpektraLab develop: %@ (%d waiting)", id.uuidString, self.developQueue.count)
                _ = await self.exportPhotos([id])
            }
            self.developRunning = false
            self.developPending = 0
        }
    }

    /// Develop and export these photos to Photos one by one, each with its own look, without showing
    /// the editor. Returns how many made it.
    func exportPhotos(_ ids: [UUID]) async -> Int {
        guard !batchExporting, editingPhotoID == nil else { return 0 }
        batchExporting = true
        defer { batchExporting = false; libraryBusy = nil }
        var done = 0
        var exported: [UUID] = []
        for (i, id) in ids.enumerated() {
            libraryBusy = nil   // `openLibraryPhoto` refuses while the wall is busy
            await openLibraryPhoto(id)
            guard editingPhotoID == id else { continue }
            libraryBusy = "正在导出 \(i + 1)/\(ids.count)"
            await export(toPhotos: true)
            if library.first(where: { $0.id == id })?.exportedAt != nil { done += 1; exported.append(id) }
            closeEditor()
        }
        // Thumbnails after the batch: each opens its own engine session, which must not land
        // between an export's open and its render.
        for id in exported {
            libraryBusy = "正在更新缩略图…"
            if let recipe = library.first(where: { $0.id == id })?.recipe { await refreshThumbnail(for: id, recipe: recipe) }
        }
        libraryMessage = done == ids.count ? "已导出 \(done) 张到相册" : "已导出 \(done) 张，\(ids.count - done) 张失败"
        return done
    }

    /// What these library photos have in Photos: a linked original (a 无胶卷 shot, a photo read in place) and the
    /// print last exported (auto-develop included).
    func photosAssets(of ids: Set<UUID>) -> [String] {
        library.filter { ids.contains($0.id) }.flatMap { [$0.assetID, $0.exportedAssetID].compactMap { $0 } }
    }

    /// Deletes pictures from Photos (iOS asks first; they go to Recently Deleted for 30 days), and drops the library
    /// entries that only pointed at them. False when refused, or nothing was found.
    @discardableResult
    func deleteFromPhotos(_ assetIDs: [String]) async -> Bool {
        guard !assetIDs.isEmpty, await PhotoAssets.authorize() else {
            libraryMessage = "没有相册权限，无法删除“照片”里的照片"
            return false
        }
        // Off the main actor: Photos runs the change block on its own queue, and a block made here inherited the
        // main actor's isolation — Swift's executor check stopped the app the moment Photos ran it.
        let count = await PhotoLibrary.deleteAssets(assetIDs)
        guard count > 0 else {
            if count == 0 { libraryMessage = "“照片”里已经没有这些照片了" }
            return false        // none found, or the person said no in iOS's own prompt
        }
        let gone = Set(assetIDs)
        deletePhotos(Set(library.filter { $0.assetID.map(gone.contains) ?? false }.map(\.id)))
        for i in library.indices where library[i].exportedAssetID.map(gone.contains) ?? false {
            library[i].exportedAssetID = nil
        }
        saveLibraryManifest()
        libraryMessage = "已从“照片”删除 \(count) 张"
        return true
    }

    /// Several system photos linked at once, in the order given (for paste, pair and copy).
    func linkAssets(_ ids: [String]) async -> [UUID] {
        var out: [UUID] = []
        for id in ids { if let linked = await linkAsset(id) { out.append(linked) } }
        return out
    }

    private func originalURL(for photo: LibraryPhoto) -> URL {
        libraryRoot.appendingPathComponent(photo.fileName)
    }

    /// A film's or a paper's display name (callers pass either: a roll's paper went through here and showed its id).
    func filmName(for stock: String) -> String {
        if stock.isEmpty { return "无胶片" }
        return (films.first { $0.id == stock } ?? papers.first { $0.id == stock })?.name ?? stock
    }

    /// A film's name for a small tile: the maker dropped, two words at most ("Kodak Portra 400" → "Portra 400").
    func shortFilmName(for stock: String) -> String {
        var name = filmName(for: stock)
        for maker in ["Kodak ", "Fujifilm ", "Fuji ", "Ilford ", "CineStill ", "Agfa ", "Lomography ", "Harman ", "Polaroid "]
        where name.hasPrefix(maker) { name.removeFirst(maker.count) }
        return name.split(separator: " ").prefix(2).joined(separator: " ")
    }

    private func prepareLibraryRoot() {
        let root = libraryRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = root
        try? mutable.setResourceValues(values)
    }

    private func loadLibrary() {
        prepareLibraryRoot()
        guard let data = try? Data(contentsOf: libraryRoot.appendingPathComponent("library.json")),
              let entries = try? JSONDecoder().decode([LibraryManifestEntry].self, from: data)
        else { return }
        library = entries.compactMap { entry in
            let thumbURL = thumbnailURL(for: entry.id)
            guard let thumbnail = UIImage(contentsOfFile: thumbURL.path) else { return nil }
            return LibraryPhoto(id: entry.id,
                                name: entry.name,
                                fileName: entry.fileName,
                                typeIdentifier: entry.typeIdentifier,
                                pixelWidth: entry.pixelWidth,
                                pixelHeight: entry.pixelHeight,
                                sourceAspect: entry.sourceAspect,
                                createdAt: entry.createdAt,
                                recipe: entry.recipe,
                                crop: entry.crop,
                                pair: entry.pair,
                                favorite: entry.favorite ?? false,
                                captured: entry.captured ?? false,
                                frameNumber: entry.frameNumber,
                                assetID: entry.assetID,
                                exportedAt: entry.exportedAt,
                                capturedAt: entry.capturedAt,
                                importedFrom: entry.importedFrom,
                                cameraEV: entry.cameraEV,
                                exportedAssetID: entry.exportedAssetID,
                                exportedLook: entry.exportedLook,
                                isEdited: entry.isEdited,
                                thumbnail: thumbnail)
        }.sorted { $0.createdAt > $1.createdAt }
        adoptLegacyImportList()
    }

    /// Before 2.1.x "imported before" was a list of its own, kept after a delete. Its entries go onto the photos
    /// still here (an imported copy whose name matches); the rest were deleted and may come in again.
    private func adoptLegacyImportList() {
        guard let legacy = UserDefaults.standard.stringArray(forKey: Self.importedSourcesKey) else { return }
        for key in legacy {
            let file = String(key.split(separator: "|", maxSplits: 1).first ?? "")
            let stem = (file as NSString).deletingPathExtension
            if let i = library.firstIndex(where: { $0.importedFrom == nil && !$0.fileName.isEmpty && !$0.captured && $0.name == stem }) {
                library[i].importedFrom = key
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.importedSourcesKey)
        saveLibraryManifest()
    }

    /// Reads each photo's shooting date once and keeps it in the manifest (the wall sorts by it):
    /// the Photos asset's date, the original's EXIF, else when it joined the library.
    func fillCaptureDates() async {
        // Before 2.1.x a 无胶卷 shot was also linked into 底片 (linked + captured: nothing else makes those). It lives
        // in Photos only now: drop the untouched entries (Photos keeps the picture); edited ones keep their look.
        // shortcut: one-time cleanup; drop once no old library is left.
        if editingPhotoID == nil {
            let plain = Set(library.filter { $0.captured && $0.assetID != nil && !$0.isEdited }.map(\.id))
            if !plain.isEmpty { deletePhotos(plain) }
        }
        // Before 2.1.x an import started on Portra 400 while its thumbnail showed the original: untouched ones
        // become 无胶片 once (exported or pairs keep their film).
        let importsKey = "SpektraLab.importsNoFilmDone"
        if editingPhotoID == nil, !UserDefaults.standard.bool(forKey: importsKey) {
            for i in library.indices where !library[i].captured && !library[i].isEdited && library[i].exportedAt == nil
                && library[i].pair == nil && library[i].recipe.noFilm == nil {
                library[i].recipe.noFilm = true
            }
            saveLibraryManifest()
            UserDefaults.standard.set(true, forKey: importsKey)
        }
        // 2.1.0 build 7–8: a roll's look inherited the new-photo 无胶片 flag, so shots on a film roll were kept as
        // 无胶片. Untouched ones get their roll's film back (once) and a developed thumbnail.
        let rollKey = "SpektraLab.rollNoFilmFixed"
        if editingPhotoID == nil, !UserDefaults.standard.bool(forKey: rollKey) {
            for i in library.indices where library[i].captured && library[i].assetID == nil
                && !library[i].isEdited && library[i].recipe.noFilm == true {
                library[i].recipe.noFilm = nil
                thumbnailsToDevelop.append(library[i].id)
            }
            saveLibraryManifest()
            UserDefaults.standard.set(true, forKey: rollKey)
            if !thumbnailsToDevelop.isEmpty { await developImportThumbnails() }
        }
        // 2026-11-17 builds gave imports 相机测光 too; the owner wants it for camera shots only. Untouched ones
        // go back to the engine's meter, once.
        let importsMeterKey = "SpektraLab.importsEngineMeterFixed"
        if editingPhotoID == nil, !UserDefaults.standard.bool(forKey: importsMeterKey) {
            for i in library.indices where !library[i].captured && !library[i].isEdited
                && library[i].recipe.exposureMethod == PhotoRecipe.newPhotoMeter {
                library[i].recipe.exposureMethod = nil
            }
            saveLibraryManifest()
            UserDefaults.standard.set(true, forKey: importsMeterKey)
        }
        let missing = library.filter { $0.capturedAt == nil }
        guard !missing.isEmpty else { return }
        var found: [UUID: Date] = [:]
        for p in missing {
            if let id = p.assetID {
                found[p.id] = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject?.creationDate ?? p.createdAt
            } else if p.captured || p.pair != nil || p.fileName.isEmpty {
                found[p.id] = p.createdAt
            } else {
                let url = originalURL(for: p)
                found[p.id] = await Task.detached(priority: .utility) { Self.exifDate(url) }.value ?? p.createdAt
            }
        }
        for i in library.indices { if let d = found[library[i].id] { library[i].capturedAt = d } }
        saveLibraryManifest()
    }

    /// EXIF DateTimeOriginal (TIFF DateTime as a fallback), read from the header only.
    nonisolated static func exifDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text)
    }

    private func saveLibraryManifest() {
        prepareLibraryRoot()
        let entries = library.map { photo in
            LibraryManifestEntry(id: photo.id,
                                 name: photo.name,
                                 fileName: photo.fileName,
                                 typeIdentifier: photo.typeIdentifier,
                                 pixelWidth: photo.pixelWidth,
                                 pixelHeight: photo.pixelHeight,
                                 sourceAspect: photo.sourceAspect,
                                 createdAt: photo.createdAt,
                                 recipe: photo.recipe,
                                 crop: photo.crop,
                                 pair: photo.pair,
                                 favorite: photo.favorite ? true : nil,
                                 captured: photo.captured ? true : nil,
                                 frameNumber: photo.frameNumber,
                                 assetID: photo.assetID,
                                 exportedAt: photo.exportedAt,
                                 capturedAt: photo.capturedAt,
                                 importedFrom: photo.importedFrom,
                                 cameraEV: photo.cameraEV,
                                 exportedAssetID: photo.exportedAssetID,
                                 exportedLook: photo.exportedLook,
                                 isEdited: photo.isEdited)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: libraryRoot.appendingPathComponent("library.json"), options: .atomic)
    }

    private func loadClipboardRecipe() {
        guard let data = UserDefaults.standard.data(forKey: Self.clipboardRecipeKey),
              let recipe = try? JSONDecoder().decode(PhotoRecipe.self, from: data)
        else { return }
        clipboardRecipe = recipe
        if let raw = UserDefaults.standard.string(forKey: Self.clipboardRecipeSourceKey),
           let id = UUID(uuidString: raw),
           library.contains(where: { $0.id == id }) {
            recipeSourcePhotoID = id
        }
    }

    private func saveClipboardRecipe(_ recipe: PhotoRecipe) {
        UserDefaults.standard.set(try? JSONEncoder().encode(recipe),
                                  forKey: Self.clipboardRecipeKey)
        if let recipeSourcePhotoID {
            UserDefaults.standard.set(recipeSourcePhotoID.uuidString,
                                      forKey: Self.clipboardRecipeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.clipboardRecipeSourceKey)
        }
    }

    /// Switch the editor's controls to a stored look. Missing parameter keys
    /// are filled from the catalogue by `normalizedParams`.
    private func apply(_ stored: PhotoRecipe) {
        layer2Source = nil
        recipe = normalized(stored)
    }

    /// Open a wall photo in the editor. The wall stays on screen with a small
    /// progress label until the engine has the first preview, so the editor
    /// never appears as an empty "add a photo" screen.
    func openLibraryPhoto(_ id: UUID) async {
        guard libraryBusy == nil,
              let photo = library.first(where: { $0.id == id }) else { return }
        guard engine != nil else {
            libraryMessage = "引擎还在准备，请稍后再试"
            return
        }
        libraryBusy = "正在打开 \(photo.name)…"
        await ensureCameraEV(id)
        apply(photo.recipe)
        crop = photo.crop ?? FrameCrop()
        dateStampDate = photo.createdAt
        shootingDataText = "1/125  F2.8  ISO 400  50mm"
        do {
            let data = try await originalData(for: photo)
            let hint = photo.typeIdentifier.flatMap(UTType.init)
            try await loadPhoto(data: data, typeHint: hint, name: photo.name)
            // As normalised against this photo, so opening and closing it untouched is no edit.
            editingBaseRecipe = recipe
            editingPhotoID = id
            resetHistory()
            libraryBusy = nil
            libraryMessage = nil
        } catch {
            libraryBusy = nil
            libraryMessage = "无法打开 \(photo.name)：\(error.localizedDescription)"
            state = .failed(error.localizedDescription)
        }
    }

    /// Leave the editor and put the current look back on the wall. The recipe
    /// is saved synchronously; the thumbnail is refreshed right after, so
    /// returning never waits for a second render.
    func closeEditor() {
        guard let id = editingPhotoID else { return }
        let recipe = currentRecipe
        let changed = recipe != editingBaseRecipe
        if let data = try? JSONEncoder().encode(recipe) { UserDefaults.standard.set(data, forKey: Self.lastRecipeKey) }
        if let index = library.firstIndex(where: { $0.id == id }) {
            library[index].recipe = recipe
            library[index].isEdited = library[index].isEdited || changed
        }
        saveLibraryManifest()
        renderTask?.cancel()
        editingPhotoID = nil
        settled = nil
        undoStack = []
        redoStack = []
        editingBaseRecipe = nil
        libraryMessage = nil
        // A batch export refreshes its thumbnails after the batch (see `exportPhotos`).
        if !batchExporting {
            Task { @MainActor [weak self] in
                await self?.refreshThumbnail(for: id, recipe: recipe)
            }
        }
    }

    /// Copy one photo's look for the paste action. The recipe is also written
    /// to the app's own clipboard (and the system pasteboard as JSON), so it
    /// survives a relaunch without reading the user's pasteboard unasked.
    func copyRecipe(from id: UUID) {
        guard let photo = library.first(where: { $0.id == id }) else { return }
        clipboardRecipe = photo.recipe
        recipeSourcePhotoID = id
        saveClipboardRecipe(photo.recipe)
        libraryMessage = "已复制 \(filmName(for: photo.recipe.filmID)) 配方"
        if let data = try? JSONEncoder().encode(photo.recipe) {
            UIPasteboard.general.string = "spektralab-recipe:v1:" + data.base64EncodedString()
        }
    }

    // MARK: - 白平衡 eyedropper (曝光 › 白平衡)

    /// The eyedropper is out: the next tap on the picture is a grey to balance on.
    @Published var pickingNeutral = false
    /// What the last pick did, or why it could not.
    @Published var neutralNote: String?

    /// Why the eyedropper cannot be used on this photo now, or nil.
    var neutralRefusal: String? {
        if recipe.noFilm == true { return "无胶片时不能用：先选一款胶片。" }
        if filmBorderEnabled { return "开着片边时不能用：先关掉片边，校正后再打开。" }
        if frame == nil { return "照片还在载入。" }
        return nil
    }

    /// A tap at `n` (normalised, top-left) of the picture shown: the frame there, already through the current
    /// balance, made grey on top of it.
    func pickNeutral(at n: CGPoint) {
        pickingNeutral = false
        if let why = neutralRefusal { neutralNote = why; return }
        guard let c = frame?.sample(at: n) else { neutralNote = "请点在照片上。"; return }
        guard let g = SceneBalance.gains(neutralizing: c) else { neutralNote = "这里太暗，看不出颜色：换一块亮一点的灰色或白色。"; return }
        let next = SceneBalance.combined(recipe.sceneBalance, g)
        edit { $0.sceneBalance = next }
        neutralNote = "已校正：" + SceneBalance.describe(next)
    }

    /// Forget the copied look (the wall's banner ✕ and the photo menus' 清除).
    func clearClipboard() {
        clipboardRecipe = nil
        recipeSourcePhotoID = nil
        UserDefaults.standard.removeObject(forKey: Self.clipboardRecipeKey)
        UserDefaults.standard.removeObject(forKey: Self.clipboardRecipeSourceKey)
        libraryMessage = "已清除复制的配方"
    }

    /// Apply the copied look to every selected photo and refresh each wall
    /// thumbnail. This is serial on purpose: one engine session is reused, so
    /// a hundred selected photos do not become a hundred GPU sessions.
    func pasteRecipe(to ids: Set<UUID>) async {
        guard let recipe = clipboardRecipe else {
            libraryMessage = "先在一张照片上复制配方"
            return
        }
        await applyRecipe(recipe, to: ids)
    }

    /// Give these photos a look (a pasted or saved recipe) and refresh their thumbnails.
    func applyRecipe(_ recipe: PhotoRecipe, to ids: Set<UUID>) async {
        let targets = library.filter {
            ids.contains($0.id) && $0.id != recipeSourcePhotoID
        }
        guard !targets.isEmpty else { return }
        libraryBusy = "正在粘贴配方 0/\(targets.count)"
        var failed = 0
        for (offset, target) in targets.enumerated() {
            libraryBusy = "正在粘贴配方 \(offset + 1)/\(targets.count)"
            guard let index = library.firstIndex(where: { $0.id == target.id }) else { continue }
            library[index].recipe = recipe
            library[index].isEdited = true
            do {
                let image = try await renderThumbnail(for: library[index], recipe: recipe)
                library[index].thumbnail = image
                try LibraryThumbnail.saveJPEG(image, to: thumbnailURL(for: target.id))
            } catch {
                failed += 1
            }
            await Task.yield()
        }
        saveLibraryManifest()
        libraryBusy = nil
        libraryMessage = failed == 0
            ? "已把配方套用到 \(targets.count) 张照片"
            : "已套用 \(targets.count - failed) 张，\(failed) 张缩略图未更新"
    }

    /// Delete photos and their on-disk originals. The manifest is rewritten
    /// after the files are gone, so a crash mid-delete leaves either an entry
    /// with a missing file (skipped on next launch) or no entry at all.
    func deletePhotos(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            // A photo read from the system library has no file here: Photos keeps its original.
            if let photo = library.first(where: { $0.id == id }), photo.assetID == nil, !photo.fileName.isEmpty {
                try? FileManager.default.removeItem(at: originalURL(for: photo))
            }
            try? FileManager.default.removeItem(at: thumbnailURL(for: id))
            try? FileManager.default.removeItem(at: largeDevelopURL(for: id))
        }
        if let editing = editingPhotoID, ids.contains(editing) {
            editingPhotoID = nil
            editingBaseRecipe = nil
        }
        if let source = recipeSourcePhotoID, ids.contains(source) {
            recipeSourcePhotoID = nil
            UserDefaults.standard.removeObject(forKey: Self.clipboardRecipeSourceKey)
        }
        library.removeAll { ids.contains($0.id) }
        saveLibraryManifest()
        libraryMessage = "已删除 \(ids.count) 张照片"
    }

    func clearLibraryMessage() {
        libraryMessage = nil
    }

    /// Imports whose thumbnail ImageIO could not make (LibRaw's formats): developed one at a time once the
    /// import loop is done. Run alongside the loop, RAW decodes overlapped (ImageIO then refused other RAWs'
    /// thumbnails) and each put back the status it found, leaving "正在导入 11/24" on screen.
    private var thumbnailsToDevelop: [UUID] = []

    private func developImportThumbnails() async {
        let ids = thumbnailsToDevelop
        thumbnailsToDevelop = []
        for (i, id) in ids.enumerated() {
            guard let photo = library.first(where: { $0.id == id }) else { continue }
            libraryBusy = "正在生成缩略图 \(i + 1)/\(ids.count)"
            await refreshThumbnail(for: id, recipe: photo.recipe)
        }
        libraryBusy = nil
    }

    private func refreshThumbnail(for id: UUID, recipe: PhotoRecipe) async {
        guard let index = library.firstIndex(where: { $0.id == id }) else { return }
        let previousBusy = libraryBusy
        libraryBusy = "正在更新缩略图…"
        defer { libraryBusy = previousBusy }
        guard let image = try? await renderThumbnail(for: library[index], recipe: recipe) else { return }
        guard let current = library.firstIndex(where: { $0.id == id }) else { return }
        library[current].thumbnail = image
        try? LibraryThumbnail.saveJPEG(image, to: thumbnailURL(for: id))
        saveLibraryManifest()
    }

    /// Render one wall-sized print through the real engine. `preview_long_edge`
    /// is set to the thumbnail size, so this is a lookup-sized render rather
    /// than a full live-tier one per photo.
    /// One photo developed at `longEdge` px through the engine with its look, crop and 后期: the light table's
    /// slide show. Nil while the editor or an export holds the engine.
    func slideImage(for id: UUID, longEdge: Int = 2048) async -> UIImage? {
        guard editingPhotoID == nil, !exporting, !batchExporting, developPending == 0,
              let photo = library.first(where: { $0.id == id }) else { return nil }
        return try? await renderThumbnail(for: photo, recipe: photo.recipe, longEdge: longEdge)
    }

    private func renderThumbnail(for photo: LibraryPhoto, recipe: PhotoRecipe, longEdge: Int = 900) async throws -> UIImage {
        guard let engine else { throw EngineError.failed(status: -1, message: "引擎没有启动") }
        let data = try await originalData(for: photo)
        let hintID = photo.typeIdentifier
        let photoCrop = photo.crop
        let sceneGains = recipe.sceneBalance
        if recipe.noFilm == true {
            var image = try await Task.detached(priority: .userInitiated) {
                try Self.plainPicture(data, maxLongEdge: longEdge, crop: photoCrop, space: Layer2Renderer.previewSpace,
                                      typeHint: hintID.flatMap(UTType.init))
            }.value
            if let a = recipe.adjustments, a.isActive, let layer2 = Layer2Renderer.shared {
                image = try layer2.image(try layer2.source(image), a, space: Layer2Renderer.previewSpace)
            }
            image = Watermark.composite(image, watermarkShelf.resolved(recipe.watermarks))
            return longEdge > 900 ? UIImage(cgImage: image) : LibraryThumbnail.downscale(image)
        }
        let decoded = try await Task.detached(priority: .userInitiated) {
            try ImageDecoder.decode(data: data,
                                    maxLongEdge: max(1400, longEdge * 5 / 4),
                                    typeHint: hintID.flatMap(UTType.init)).applying(photoCrop).balanced(sceneGains)
        }.value
        let sourceAspect = photoCrop == nil ? CGFloat(photo.sourceAspect)
            : CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
        let gate = FilmGateCatalog.resolve(selection: recipe.overscanFormat,
                                           imageAspect: sourceAspect)
        let orientation = FilmStripOrientation(rawValue: recipe.stripOrientation) ?? .automatic
        let framed = recipe.filmBorderEnabled
            ? decoded.centerCropped(toTargetAspect: orientation.targetAspect(for: gate,
                                                                            sourceAspect: sourceAspect))
            : decoded
        var cameraEV = photo.cameraEV
        if cameraEV == nil, recipe.exposureMethod == "camera" {
            cameraEV = await Task.detached(priority: .userInitiated) {
                ImageDecoder.cameraExposureEV(data: data, typeHint: hintID.flatMap(UTType.init))
            }.value
            if let ev = cameraEV, let i = library.firstIndex(where: { $0.id == photo.id }) {
                library[i].cameraEV = ev
                saveLibraryManifest()
            }
        }
        var delta = recipe.engineDelta(filmName: filmName(for: recipe.filmStock),
                                       frameNumber: photo.frameNumber ?? 12,
                                       imageAspect: sourceAspect,
                                       stamp: photo.createdAt,
                                       shootingData: "1/125  F2.8  ISO 400  50mm",
                                       cameraEV: cameraEV)
        delta[ParamDefaults.productDefaultsKey] = .bool(true)
        delta["preview_long_edge"] = .number(Double(longEdge))
        let openDelta = delta
        let bitmap = try await engine.perform {
            try framed.pixels.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    throw EngineError.failed(status: -1, message: "解码结果为空")
                }
                _ = try engine.open(pixels: EnginePixels(data: base,
                                                         width: framed.width,
                                                         height: framed.height),
                                    params: openDelta)
            }
            try engine.solve(target: "both")
            return try engine.renderBitmap(tier: "live", reprint: false)
        }
        var picture = bitmap.cgImage
        if let a = recipe.adjustments, a.isActive, let layer2 = Layer2Renderer.shared {
            picture = try layer2.image(try layer2.source(bitmap.cgImage), a, space: Layer2Renderer.previewSpace)
        }
        picture = Watermark.composite(picture, watermarkShelf.resolved(recipe.watermarks))
        return longEdge > 900 ? UIImage(cgImage: picture) : LibraryThumbnail.downscale(picture)
    }

    /// Load an already-decoded frame: open a session and render the first
    /// preview.
    private func loadFrame(_ decoded: DecodedFrame) async throws {
        guard let engine else { throw EngineError.failed(status: -1, message: "引擎没有启动") }
        frame = decoded
        sourceSize = CGSize(width: decoded.width, height: decoded.height)

        // Open with the current stocks and parameters, so the first preview
        // already shows what the user chose.
        let openDelta = currentOpenDelta()

        // The pointer has to stay alive across the `open` call: the engine
        // borrows the pixels for the duration of that call and copies what it
        // keeps, so the buffer must not go out of scope before it returns.
        // Taking the address inside a closure and using it outside would
        // leave it dangling -- which reads as a frame of noise rather than
        // as a crash, and is much harder to find.
        let reply = try await engine.perform {
            try decoded.pixels.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    throw EngineError.failed(status: -1, message: "解码结果为空")
                }
                return try engine.open(pixels: EnginePixels(
                    data: base,
                    width: decoded.width,
                    height: decoded.height), params: openDelta)
            }
        }

        if let meta = reply.meta, let w = meta.width, let h = meta.height {
            sourceSize = CGSize(width: w, height: h)
        }

        // The solve must happen before the first render, or the print uses
        // default exposure and the highlights blow out — which looks like a
        // rendering bug and is not one.
        try await engine.perform { try engine.solve(target: "both") }

        await renderNow()
    }

    // MARK: - parameters

    /// Dismiss an error notice without losing the picture already on screen.
    func dismissFailure() {
        if case .failed = state {
            state = renderedTexture == nil ? .empty : .ready
        }
    }

    /// A parameter changed. Mark the render stale and schedule one.
    /// Turn the physical film edge on or off. The picture is re-opened at the gate's shape
    /// (`respond` reloads it): the engine refuses a crop that is not the format's.
    func setFilmBorderEnabled(_ enabled: Bool) { edit { $0.filmBorderEnabled = enabled } }

    /// Pick an explicit gate, or automatic matching against the photograph.
    func setOverscanFormat(_ id: String) {
        guard id == FilmGateCatalog.automaticID || FilmGateCatalog.gate(id: id) != nil else { return }
        edit { $0.overscanFormat = id }
    }

    /// Which way the strip runs; re-crops the frame, never rotates the picture.
    func setStripOrientation(_ orientation: FilmStripOrientation) {
        guard !selectedGate.isSquare || orientation == .automatic else { return }
        edit { $0.stripOrientation = orientation.rawValue }
    }

    func setDateBackEnabled(_ enabled: Bool) {
        guard !enabled || selectedGate.supportsDateBack else { return }
        edit { $0.dateBackEnabled = enabled }
    }
    func setDateBackStyle(_ style: DateBackStyle) { edit { $0.dateBackStyle = style.rawValue } }
    func setDateBackPlacement(_ placement: DateBackPlacement) { edit { $0.dateBackPlacement = placement.rawValue } }
    func setDateBackCorner(_ corner: DateBackCorner) { edit { $0.dateBackCorner = corner.rawValue } }

    func setDateStampDate(_ date: Date) {
        guard date != dateStampDate else { return }
        dateStampDate = date
        scheduleEffectRender()
    }

    func setShootingDataText(_ text: String) {
        guard text != shootingDataText else { return }
        shootingDataText = text
        scheduleEffectRender()
    }

    private func scheduleEffectRender() {
        guard frame != nil else { return }
        paramsDirty = true
        scheduleRender()
    }

    /// A gate change has to reload the preview because the crop is applied
    /// before the engine sees the frame. A toggle-off reloads the full frame,
    /// restoring the part the rebate had cropped away.
    private func reloadPreviewForFilmEffect() {
        guard !exporting else { return }
        guard originalData != nil else {
            scheduleEffectRender()
            return
        }
        effectReloadNeeded = true
        guard !effectReloadRunning else { return }
        effectReloadRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.effectReloadNeeded {
                self.effectReloadNeeded = false
                self.state = .importing
                self.statusText = self.filmBorderEnabled
                    ? "正在裁切到 \(self.gateDisplayName)…"
                    : "正在重新曝光…"
                do {
                    guard let data = self.originalData else { break }
                    let sourceGeneration = self.sourceGeneration
                    let hint = self.originalTypeHint
                    let crop = self.crop
                    let gains = self.recipe.sceneBalance
                    let decoded = try await Task.detached(priority: .userInitiated) {
                        try ImageDecoder.decode(data: data,
                                                maxLongEdge: ImageDecoder.previewLongEdge,
                                                typeHint: hint).applying(crop).balanced(gains)
                    }.value
                    guard sourceGeneration == self.sourceGeneration else { continue }
                    self.naturalAspect = CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
                    self.recipe = self.normalized(self.recipe)
                    let framed = self.filmBorderEnabled
                        ? decoded.centerCropped(toTargetAspect: self.filmCropAspect)
                        : decoded
                    try await self.loadFrame(framed)
                } catch {
                    self.state = .failed(error.localizedDescription)
                    self.statusText = "片边载入失败"
                }
            }
            self.effectReloadRunning = false
            if self.effectReloadNeeded { self.reloadPreviewForFilmEffect() }
        }
    }

    /// The film changed: its own paper comes with it (a silver film its silver paper), or the
    /// paper whose preview table was baked for it. `respond` reopens.
    func filmChanged(_ stock: String) {
        edit { r in
            r.noFilm = nil
            r.filmStock = stock
            r.printStock = paper(for: stock)     // as a shot on this film prints (camera roll: the same rule)
        }
    }

    /// 相机测光's measure for a photo, once: how far its linear decode sits under the camera's own develop of it.
    func ensureCameraEV(_ id: UUID) async {
        guard let photo = library.first(where: { $0.id == id }), photo.cameraEV == nil,
              let data = try? await originalData(for: photo) else { return }
        let hint = photo.typeIdentifier.flatMap(UTType.init)
        let ev = await Task.detached(priority: .userInitiated) { ImageDecoder.cameraExposureEV(data: data, typeHint: hint) }.value
        guard let ev, let i = library.firstIndex(where: { $0.id == id }) else { return }
        library[i].cameraEV = ev
        saveLibraryManifest()
        NSLog("SpektraLab camera meter: %@ %+.2f EV", photo.name, ev)
    }

    /// The paper a film prints on when it is chosen — the editor and a camera roll use this one rule, so a shot and
    /// the same film picked later match. A silver film: its own paper; else the recommended paper last picked for it
    /// in the camera's 冲印 menu, or its first (`StockCatalog.recommendedPapers`); else Crystal Archive. A paper
    /// outside the recommendations, picked in the camera, lasts one visit (`CameraView.paperPick`).
    func paper(for film: String) -> String {
        if catalog.isMonochrome(film), let own = catalog.ownPaper(of: film) { return own }
        let recommended = StockCatalog.recommendedPapers(for: film).filter { catalog.canPrint(film: film, on: $0) }
        // One of its recommended papers picked in the camera's 冲印 menu stays this film's paper.
        if let picked = UserDefaults.standard.string(forKey: StockCatalog.filmPaperKey(film)), recommended.contains(picked) {
            return picked
        }
        if let first = recommended.first { return first }
        return catalog.canPrint(film: film, on: StockCatalog.defaultPaper) ? StockCatalog.defaultPaper
            : (catalog.ownPaper(of: film) ?? StockCatalog.factoryPaper)
    }

    func chooseNoFilm() { edit { $0.noFilm = true } }

    /// 无胶片: the original as the system renders it (RAW with its default look), scaled to `maxLongEdge`,
    /// cut by the photo's crop, in `space`, 16-bit.
    nonisolated static func plainPicture(_ data: Data, maxLongEdge: Int, crop: FrameCrop?,
                                         space: CGColorSpace, typeHint: UTType? = nil) throws -> CGImage {
        var image = CIImage(data: data, options: [.applyOrientationProperty: true])
        // ImageIO's own size: a RAW Core Image cannot develop comes back nil or as its embedded preview.
        let props = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let declared = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let isRAW = typeHint?.conforms(to: .rawImage) == true
        // A RAW under 1024 px is its embedded preview (Mamiya MEF's 192×144 TIFF, which ImageIO also declares).
        if image.map({ let long = Int(max($0.extent.width, $0.extent.height))
            return long * 2 < declared || (isRAW && (long < 1024 || ImageDecoder.isBlack($0))) }) ?? true {
            image = try linearImage(ImageDecoder.decode(data: data, maxLongEdge: maxLongEdge, typeHint: typeHint))
        }
        guard var image else { throw DecodeError.unreadable("无法读取原图") }
        let long = max(image.extent.width, image.extent.height)
        if long > CGFloat(maxLongEdge) {
            let s = CGFloat(maxLongEdge) / long
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let r = image.extent.integral
        guard let whole = context.createCGImage(image, from: r, format: .RGBA16, colorSpace: space) else {
            throw DecodeError.unreadable("无法渲染原图")
        }
        guard let crop, !crop.isIdentity else { return whole }
        return crop.render(whole, space: space) ?? whole
    }

    /// A decoded frame (linear ProPhoto floats, LibRaw's for the formats Core Image cannot read) as a CIImage.
    nonisolated private static func linearImage(_ frame: DecodedFrame) throws -> CIImage {
        guard let linear = ImageDecoder.linearProPhoto else { throw DecodeError.unreadable("ProPhoto RGB is unavailable") }
        let n = frame.width * frame.height
        var rgba = [Float16](repeating: 1, count: n * 4)
        frame.pixels.withUnsafeBufferPointer { p in
            // LibRaw's frame is the bare sensor exposure, with none of the lift a camera's own rendering adds (a
            // Kodak DCR looked dark next to the same photo on film, which the engine meters). Meter it like the
            // film path: log-average luminance to 18 % grey, within ±2 EV.
            var sum = 0.0, count = 0
            for i in stride(from: 0, to: n, by: 7) {
                let y = 0.288 * Double(p[i * 3]) + 0.712 * Double(p[i * 3 + 1])   // ProPhoto luminance
                sum += log(max(y, 1e-4)); count += 1
            }
            let gain = Float(min(max(0.18 / exp(sum / Double(max(count, 1))), 0.25), 4))
            for i in 0..<n {
                rgba[i * 4] = Float16(p[i * 3] * gain); rgba[i * 4 + 1] = Float16(p[i * 3 + 1] * gain)
                rgba[i * 4 + 2] = Float16(p[i * 3 + 2] * gain)
            }
        }
        return CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: frame.width * 8,
                       size: CGSize(width: frame.width, height: frame.height), format: .RGBAh, colorSpace: linear)
    }

    func paperChanged(_ stock: String) {
        guard catalog.canPrint(film: filmStock, on: stock) else {
            statusText = catalog.isMonochrome(filmStock) ? "黑白胶片只能印在黑白相纸上" : "黑白相纸只能印黑白胶片"
            return
        }
        edit { $0.printStock = stock }
    }

    // MARK: - film grid (胶片 › 对比)

    /// The photo developed through each film on its own paper, small, as they arrive; keyed by film id.
    @Published private(set) var filmGrid: [String: UIImage] = [:]
    @Published private(set) var filmGridRunning = false
    private var filmGridTask: Task<Void, Never>?
    /// The look the grid was made for (photo + recipe + crop): reopened unchanged, the cards are shown at once.
    private var filmGridKey: String?
    /// The engine's one session is the grid's while it runs: the editor's renders wait (`scheduleRender`).
    private var engineLent = false

    /// Develops the open photo's frame (≈ 480 px) through every film, one open after another on the engine's
    /// session, then gives the session back to the editor. Upstream's film cards (2.4.1 `StockPreviews`), as a sheet:
    /// the frame's own look, without the film edge, the date and 后期.
    func startFilmGrid() {
        guard filmGridTask == nil, !exporting, recipe.noFilm != true, let frame, let engine else { return }
        // Which film and paper the photo has now does not change any card (each has its own): not in the key.
        var keyed = currentRecipe; keyed.filmStock = ""; keyed.printStock = ""
        let key = "\(editingPhotoID?.uuidString ?? "")|\(exportLookKey(recipe: keyed, crop: crop.isIdentity ? nil : crop))"
        if key != filmGridKey { filmGrid = [:]; filmGridKey = key }
        // The film on the photo first, then the shelf in order; cards already made are kept.
        let ids = ([filmStock] + films.map(\.id)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .filter { filmGrid[$0] == nil }
        guard !ids.isEmpty else { return }
        filmGridRunning = true
        engineLent = true
        // Small and colour-only: a card is for comparing colour and tone, so grain, halation, glare, the lens's
        // blur, leaks and diffusion are off (they cost most of a develop and do not show at this size).
        let small = frame.downsampled(longEdge: 320)
        filmGridTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for id in ids {
                if Task.isCancelled { break }
                var r = self.currentRecipe
                r.noFilm = nil
                r.filmStock = id
                r.printStock = self.paper(for: id)
                r = self.normalized(r)
                r.filmBorderEnabled = false
                r.dateBackEnabled = false
                var delta = r.engineDelta(filmName: self.filmName(for: id), frameNumber: 12,
                                          imageAspect: CGFloat(small.width) / CGFloat(max(small.height, 1)),
                                          stamp: self.dateStampDate, shootingData: self.shootingDataText,
                                          cameraEV: self.editingPhoto?.cameraEV)
                delta[ParamDefaults.productDefaultsKey] = .bool(true)
                delta["preview_long_edge"] = .number(800)        // the engine's least (800…8192; 480 was refused)
                for (k, v) in [("grain_active", ParamValue.bool(false)), ("halation_active", .bool(false)),
                               ("glare_active", .bool(false)), ("lens_blur_um", .number(0)), ("leak_kind", .string("off")),
                               ("leak_edge", .number(0)), ("diffusion_filter_active", .bool(false)),
                               ("lens_aberrations_active", .bool(false))] { delta[k] = v }
                let open = delta
                let started = Date()
                do {
                    let image = try await engine.perform { () -> CGImage in
                        try small.pixels.withUnsafeBufferPointer { buffer in
                            guard let base = buffer.baseAddress else { throw EngineError.failed(status: -1, message: "空") }
                            _ = try engine.open(pixels: EnginePixels(data: base, width: small.width, height: small.height),
                                                params: open)
                        }
                        try engine.solve(target: "both")
                        return try engine.renderBitmap(tier: "live", reprint: false).cgImage
                    }
                    self.filmGrid[id] = UIImage(cgImage: image)
                    NSLog("SpektraLab film grid: %@ %.0f ms", id, Date().timeIntervalSince(started) * 1000)
                } catch {
                    NSLog("SpektraLab film grid: %@ FAILED %@", id, error.localizedDescription)
                }
            }
            // The editor's session back, as it was.
            self.engineLent = false
            self.filmGridRunning = false
            self.filmGridTask = nil
            self.reopenAndRender()
        }
    }

    /// The sheet closed: stop after the card being made (the session is handed back then).
    func stopFilmGrid() { filmGridTask?.cancel() }

    /// Reopen the session with the current stocks and parameters.
    private func reopenAndRender() {
        // The export's bitmap still borrows the engine's buffers; reopening now
        // frees them under it (a crash). Export reopens itself when it is done.
        guard !exporting, !engineLent else { return }
        guard let frame, let engine else { return }
        let openDelta = currentOpenDelta()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await engine.perform {
                    // The pointer has to outlive the call: the engine borrows
                    // the pixels for the duration of `open` and copies what
                    // it keeps.
                    try frame.pixels.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else {
                            throw EngineError.failed(status: -1, message: "解码结果为空")
                        }
                        _ = try engine.open(pixels: EnginePixels(
                            data: base,
                            width: frame.width,
                            height: frame.height), params: openDelta)
                    }
                    try engine.solve(target: "both")
                }
                NSLog("SpektraLab reopen: session ready")
                self.paramsDirty = false
                self.scheduleRender()
            } catch {
                NSLog("SpektraLab reopen: FAILED %@", error.localizedDescription)
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - the render loop

    /// Ask for a render. It runs when the current one is done and the user
    /// has stopped moving.
    func scheduleRender() {
        guard !exporting else { return }
        needsRender = true
        guard !engineLent else { return }       // the film grid has the session; its hand-back reopens and renders
        guard !renderInFlight else { return }
        // `@MainActor` on the closure: `Task { ... }` is `@Sendable` by
        // default, and a closure that captures a `MainActor`-isolated
        // `ViewModel` is not Sendable unless the closure says where it
        // runs. Without this, Swift 6's strict concurrency rejects it.
        renderTask = Task { @MainActor [weak self] in
            // A short settle, so a drag does not render on every frame. The
            // preview is a reprint of a cached negative — fast — but not free.
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            await self?.renderNow()
        }
    }

    /// Render now, one at a time.
    private func renderNow() async {
        guard renderInFlight == false else {
            NSLog("SpektraLab render: skipped, one in flight")
            needsRender = true          // run after it: a frame opened meanwhile must still be drawn
            return
        }
        guard let engine, let renderer else { return }
        guard frame != nil else { return }
        guard !engineLent else { needsRender = true; return }
        NSLog("SpektraLab render: start (dirty %d)", paramsDirty ? 1 : 0)

        // This render is consuming the request that is currently pending.
        // A change made while it is awaiting the engine sets the flag again.
        needsRender = false
        renderInFlight = true
        defer {
            renderInFlight = false
            // A request that arrived while this render was running runs now.
            if needsRender {
                scheduleRender()
            }
        }

        state = .rendering

        do {
            let dirty = paramsDirty
            let changed = currentEngineDelta()
            let layer2 = adjustments.isActive ? Layer2Renderer.shared : nil
            let look = previewAdjustments
            let plain: CGImage?
            if recipe.noFilm == true, let data = originalData {
                let edge = ImageDecoder.previewLongEdge, c = crop, hint = originalTypeHint
                plain = try await Task.detached(priority: .userInitiated) {
                    try Self.plainPicture(data, maxLongEdge: edge, crop: c, space: Layer2Renderer.previewSpace, typeHint: hint)
                }.value
            } else { plain = nil }
            let result = try await engine.perform { () -> PreviewFrame in
                if let plain, let layer2 = Layer2Renderer.shared {
                    let source = try layer2.source(plain)
                    return PreviewFrame(texture: try layer2.texture(source, look), source: source,
                                        width: plain.width, height: plain.height, elapsedMs: 0, progressID: "")
                }
                if dirty {
                    _ = try engine.setParams(changed)
                    // The exposure has to be recomputed when the
                    // compensation changed, or the print keeps the old EV.
                    try engine.solve(target: "both")
                }

                // `live` is the interactive tier: the engine renders at the
                // live long edge (2048 px), which is what a phone screen can
                // show.
                if let layer2 {
                    let bitmap = try engine.renderBitmap(tier: "live", reprint: true)
                    let source = try layer2.source(bitmap.cgImage)
                    return PreviewFrame(texture: try layer2.texture(source, look), source: source,
                                        width: bitmap.width, height: bitmap.height,
                                        elapsedMs: bitmap.elapsedMs, progressID: "")
                }
                let r = try engine.render(tier: "live", reprint: true)
                return PreviewFrame(texture: r.texture, source: nil, width: r.width, height: r.height,
                                    elapsedMs: r.elapsedMs, progressID: r.progressID)
            }
            if dirty { paramsDirty = false }
            layer2Source = result.source
            show(result.texture)
            refreshHDR()
            renderIdentity = result.progressID.isEmpty
                ? UUID().uuidString
                : result.progressID
            lastRenderMs = result.elapsedMs
            NSLog("SpektraLab render: done %.0f ms", result.elapsedMs)
            state = .ready
            statusText = String(format: "渲染完成 · %.0f ms · %d×%d",
                                result.elapsedMs, result.width, result.height)
        } catch {
            // The state stays `.failed`. It used to be forced back to `.ready`
            // right here, which is the worst possible outcome: no error shown,
            // `renderedTexture` nil, and every slider disabled with no
            // explanation.
            NSLog("SpektraLab render: FAILED %@", error.localizedDescription)
            state = .failed(error.localizedDescription)
            statusText = "渲染失败：\(error.localizedDescription)"
        }
    }

    /// The file written off the main actor.
    private nonisolated static func write(_ image: CGImage, options: ExportOptions, source: Data?,
                                          gainMap: HDRGainMap.Attachment?) async throws -> URL {
        try ExportWriter.write(image, options: options, sourceData: source, gainMap: gainMap)
    }

    // MARK: - Enable HDR

    /// What the engine said of this session's HDR curve while the photo's HDR is on: the curve, or why none.
    @Published private(set) var hdrAnswer: HDRSessionCurve.Answer?

    /// The canvas follows the photo's switch: the session's curve asked again (it follows the paper, the
    /// exposure and the enlarger; cached by the engine), or HDR off.
    /// A slide (scanned, never printed) with HDR on and no 后期: its HDR is its two renditions' ratio. With 后期 on,
    /// the ratio of the engine's pictures would lift what the edit put down (upstream's review), so the curve.
    var isSlideHDR: Bool {
        recipe.hdr == true && catalog.stock(recipe.filmStock)?.type == .positive && !adjustments.isActive
    }

    /// The slide's two renditions on the preview session, and the canvas's gain from them.
    private func refreshSlideGain() {
        guard isSlideHDR, let engine, let device = renderer?.device else { renderer?.setSlideGain(nil, top: 1); return }
        Task { @MainActor in
            do {
                let (sdr, hdr) = try await engine.perform { () -> (CGImage, CGImage) in
                    let s = try engine.renderBitmap(tier: "live", reprint: true).cgImage
                    _ = try engine.setParams(HDRSlide.renditionDelta)
                    defer { _ = try? engine.setParams(HDRSlide.restoreDelta) }
                    let h = try engine.renderBitmap(tier: "live", reprint: true).cgImage
                    return (s, h)
                }
                let plane = await Task.detached(priority: .userInitiated) { HDRSlide.gainPlane(sdr: sdr, hdr: hdr) }.value
                guard isSlideHDR, let plane else { renderer?.setSlideGain(nil, top: 1); return }
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: plane.width, height: plane.height, mipmapped: false)
                guard let tex = device.makeTexture(descriptor: d) else { return }
                plane.log2Gain.withUnsafeBytes {
                    tex.replace(region: MTLRegionMake2D(0, 0, plane.width, plane.height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: plane.width * 4)
                }
                renderer?.setSlideGain(tex, top: plane.top)
                NSLog("SpektraLab hdr: slide gain %dx%d, top %.2f", plane.width, plane.height, plane.top)
            } catch {
                NSLog("SpektraLab hdr: slide renditions failed — %@", String(describing: error))
                renderer?.setSlideGain(nil, top: 1)
            }
        }
    }

    func refreshHDR() {
        refreshSlideGain()
        guard recipe.hdr == true, editingPhotoID != nil else {
            renderer?.setHDR(nil)
            if hdrAnswer != nil { hdrAnswer = nil }
            return
        }
        guard let engine = self.engine else { return }
        Task { @MainActor in
            let answer: HDRSessionCurve.Answer
            do {
                let json = try await engine.perform { try engine.hdrCurve() }
                answer = .curve(try HDRSessionCurve.parse(json))
            } catch {
                answer = .refused(String(describing: error))
                NSLog("SpektraLab hdr: no curve — %@", String(describing: error))
            }
            guard recipe.hdr == true else { return }
            hdrAnswer = answer
            renderer?.setHDR(answer.curve?.tables)
            if let c = answer.curve { NSLog("SpektraLab hdr: %@", c.said.description) }
        }
    }

    // MARK: - Layer 2 (后期)

    private var previewAdjustments: Adjustments { adjustments }

    /// The print's newest texture; the canvas takes it unless the original is held up.
    private func show(_ texture: MTLTexture?) {
        printTexture = texture
        guard !showingOriginal else { return }
        renderer?.setTexture(texture)
        renderedTexture = texture
        refreshHistogram()
    }

    // MARK: - histogram (⋯ › 直方图)

    static let histogramKey = "SpektraLab.showHistogram"
    /// The picture on the canvas, red / green / blue, 64 bins each; nil while hidden.
    @Published private(set) var histogram: [[Float]]?
    private var histogramQueue: MTLCommandQueue?
    private var histogramBusy = false
    private var histogramAgain = false

    /// Counts the canvas's picture again, one count at a time (a drag's renders coalesce into the last).
    func refreshHistogram() {
        guard UserDefaults.standard.bool(forKey: Self.histogramKey), let texture = renderedTexture else {
            if histogram != nil { histogram = nil }
            return
        }
        if histogramBusy { histogramAgain = true; return }
        if histogramQueue == nil { histogramQueue = texture.device.makeCommandQueue() }
        guard let queue = histogramQueue else { return }
        histogramBusy = true
        Task { @MainActor in
            let counted = await TextureHistogram.compute(texture, queue: queue)
            histogram = counted
            histogramBusy = false
            if histogramAgain { histogramAgain = false; refreshHistogram() }
        }
    }

    /// The imported file as the system decodes it, sRGB, long edge 2048.
    /// shortcut: decoded on the main thread at first press (a hitch on big RAWs); move off-main if it bothers.
    private func makeOriginalTexture() -> MTLTexture? {
        func fail(_ why: String) -> MTLTexture? { NSLog("SpektraLab original: FAILED %@", why); return nil }
        guard let originalData else { return fail("no original data") }
        guard let device = renderer?.device else { return fail("no canvas device") }
        guard let src = CGImageSourceCreateWithData(originalData as CFData, nil) else { return fail("no image source") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2048]
        guard let whole = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return fail("no thumbnail") }
        guard let space = Layer2Renderer.previewSpace as CGColorSpace?,     // the canvas's space
              let image = crop.isIdentity ? whole : crop.render(whole, space: space),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return fail("no bitmap context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.width,
                                                         height: image.height, mipmapped: false)
        guard let bytes = context.data, let texture = device.makeTexture(descriptor: d) else { return fail("no texture") }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: image.width * 4)
        NSLog("SpektraLab original: texture %dx%d", image.width, image.height)
        return texture
    }

    // MARK: - undo

    private var editSnapshot: EditSnapshot { EditSnapshot(recipe: currentRecipe, crop: crop) }

    private func resetHistory() {
        undoStack = []
        redoStack = []
        settled = editSnapshot
    }

    private func scheduleSettle() {
        guard settled != nil else { return }
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    /// The edits since the last step become one step.
    private func settle() {
        guard let before = settled else { return }
        let now = editSnapshot
        guard now != before else { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
        settled = now
    }

    func undo() {
        guard !exporting else { return }
        settleTask?.cancel()
        settle()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(editSnapshot)
        restore(previous)
    }

    func redo() {
        guard !exporting else { return }
        settleTask?.cancel()
        settle()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(editSnapshot)
        restore(next)
    }

    private func restore(_ target: EditSnapshot) {
        let now = editSnapshot
        settled = target
        // Only 后期 differs: re-run the GPU pass, no re-exposure.
        var sameLook = now.recipe
        sameLook.adjustments = target.recipe.adjustments
        if sameLook == target.recipe && now.crop == target.crop {
            setAdjustments(target.recipe.adjustments ?? Adjustments())
            return
        }
        apply(target.recipe)
        if target.crop != crop {
            crop = target.crop
            originalTexture = nil
            if let id = editingPhotoID, let index = library.firstIndex(where: { $0.id == id }) {
                library[index].crop = target.crop.isIdentity ? nil : target.crop
                saveLibraryManifest()
            }
        }
        reloadPreviewForFilmEffect()
    }

    // MARK: - library settings

    /// What a new photo starts with: the standard look, or the last one closed in the editor.
    static let newPhotoKey = "SpektraLab.newPhotoUsesLast"
    private static let lastRecipeKey = "SpektraLab.lastRecipe"

    var newPhotoRecipe: PhotoRecipe {
        guard UserDefaults.standard.bool(forKey: Self.newPhotoKey),
              let data = UserDefaults.standard.data(forKey: Self.lastRecipeKey),
              let recipe = try? JSONDecoder().decode(PhotoRecipe.self, from: data) else {
            var plain = PhotoRecipe.standard
            plain.noFilm = true          // an import starts as itself; the owner picks a film when developing
            return plain
        }
        // Imports meter with the engine, whatever the inherited look's meter (相机 belongs to camera shots).
        var inherited = recipe
        if inherited.exposureMethod == PhotoRecipe.newPhotoMeter { inherited.exposureMethod = nil }
        return inherited
    }

    func toggleFavorite(_ id: UUID) {
        guard let i = library.firstIndex(where: { $0.id == id }) else { return }
        library[i].favorite.toggle()
        saveLibraryManifest()
    }

    /// Bytes the wall keeps on disk (originals and thumbnails).
    func libraryBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: - the camera

    /// A frame from the camera, onto the wall with its roll's film and that film's paper.
    /// Returns the wall thumbnail, nil when it could not be kept.
    func addCapturedShot(_ data: Data, isRAW: Bool, look: PhotoRecipe, toPhotos: Bool = false,
                         develop: Bool = false, zoom: Double = 1, askedLongEdge: Int = 0) async -> UIImage? {
        let shots = library.filter { $0.name.hasPrefix("胶卷 ") }.count
        let type: UTType = isRAW ? (UTType("com.adobe.raw-image") ?? .rawImage) : .heic
        do {
            let id = try await addPhoto(data: data, name: String(format: "胶卷 %03d", shots + 1), typeHint: type)
            guard let index = library.firstIndex(where: { $0.id == id }) else { return nil }
            library[index].recipe = look
            library[index].captured = true
            // A RAW keeps the whole sensor whatever the digital zoom: the zoom becomes the photo's crop.
            let long = max(library[index].pixelWidth, library[index].pixelHeight)
            NSLog("SpektraLab capture: %@ %dx%d at %.2fx (asked %d)", isRAW ? "RAW" : "HEIF", library[index].pixelWidth,
                  library[index].pixelHeight, zoom, askedLongEdge)
            if isRAW, zoom > 1.01, askedLongEdge > 0, Double(long) >= 0.9 * Double(askedLongEdge) {
                library[index].crop = FrameCrop(width: 1 / zoom, height: 1 / zoom)
                NSLog("SpektraLab capture: RAW at %.2fx kept whole (%d px), cropped in the library", zoom, long)
            }
            saveLibraryManifest()
            if develop { queueDevelop(id) }
            if toPhotos {
                // A copy for Photos: `saveImage` removes the file it is given.
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SpektraCam_capture_\(id.uuidString).\(isRAW ? "dng" : "heic")")
                do {
                    try data.write(to: copy)
                    try await PhotoLibrary.saveImage(at: copy)
                } catch {
                    libraryMessage = "照片已拍好，但没能存入“照片”：\(error.localizedDescription)"
                }
            }
            return library[index].thumbnail
        } catch {
            libraryMessage = "照片没能保存：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - where the app reopens

    /// "last": where it was; "library"; "camera". Applied at launch and after two minutes away.
    static let reopenKey = "SpektraLab.reopenTo"
    /// Set when the app should show the camera; the wall presents it and clears this.
    @Published var cameraRequested = false
    /// `collectHandedOver` running.
    var handingOver = false
    private var backgroundedAt: Date?
    private var launched = false

    func sceneBecameActive() {
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        pruneExpiredNegatives()
        takeCameraRequestFromIntent()
        Task { await collectHandedOver() }
        guard !launched || away >= 120 else { return }
        launched = true
        let target = UserDefaults.standard.string(forKey: Self.reopenKey)
            ?? (UserDefaults.standard.bool(forKey: "SpektraLab.openToCamera") ? "camera" : "last")
        guard target != "last", !exporting else { return }
        if editingPhotoID != nil { closeEditor() }   // the look is saved as it closes
        if target == "camera" { cameraRequested = true }
    }

    func sceneWentToBackground() { backgroundedAt = Date() }

    // MARK: - the viewfinder's film look

    private var viewfinderLUTs: [String: Data] = [:]
    static let viewfinderLUTSize = 25

    /// A colour cube (`CIColorCubeWithColorSpace`, sRGB in and out, RGBA float, red fastest) of the
    /// roll's film on its own paper: a chart of every colour on a 25³ grid developed once through
    /// the engine. Colour and tone only — the chart is developed with every spatial effect off
    /// (grain, halation, glare, lens, leaks, edge), on a 300 mm "film" so the couplers' 20–200 µm
    /// diffusion stays inside one sample's 8 × 8 block.
    func viewfinderLUT(roll: String, paper: String? = nil) async -> Data? {
        guard var look = rollRecipe(roll, paper: paper) else { return nil }
        // A shot being developed holds the engine; the chart waits its turn.
        while batchExporting || exporting { try? await Task.sleep(nanoseconds: 300_000_000) }
        let key = (try? JSONEncoder().encode(look)).map { $0.base64EncodedString() } ?? roll
        if let cached = viewfinderLUTs[key] { return cached }
        let film = look.filmStock
        // The engine holds one session: developing the chart would take the editor's photo away.
        guard let engine, !exporting, editingPhotoID == nil else { return nil }
        let n = Self.viewfinderLUTSize, tiles = 5, block = 8
        let side = tiles * n * block
        var chart = [Float](repeating: 0, count: side * side * 3)
        for b in 0..<n {
            let tx = (b % tiles) * n, ty = (b / tiles) * n
            for g in 0..<n {
                for r in 0..<n {
                    let rgb = [Float(r), Float(g), Float(b)].map { $0 / Float(n - 1) }
                    for dy in 0..<block {
                        let row = ((ty + g) * block + dy) * side
                        for dx in 0..<block {
                            let i = (row + (tx + r) * block + dx) * 3
                            chart[i] = rgb[0]; chart[i + 1] = rgb[1]; chart[i + 2] = rgb[2]
                        }
                    }
                }
            }
        }
        // 后期 is applied to the developed chart below; its vignette is spatial and would smear the chart.
        var finish = look.adjustments ?? Adjustments()
        finish.vignette = Vignette()
        look.adjustments = nil
        var delta = look.engineDelta(filmName: filmName(for: look.filmStock), imageAspect: 1,
                                     stamp: Date(), shootingData: "")
        let off: [String: ParamValue] = [
            "input_color_space": .string("sRGB"), "input_cctf_decoding": .bool(true),
            "output_color_space": .string("sRGB"), "output_cctf_encoding": .bool(true),
            "auto_exposure": .bool(false), "film_format_mm": .number(300),
            "grain_active": .bool(false), "halation_active": .bool(false), "glare_active": .bool(false),
            "lens_blur_um": .number(0), "scene_latitude_active": .bool(false), "leak_kind": .string("off"),
            "diffusion_filter_active": .bool(false), "lens_aberrations_active": .bool(false),
            "overscan_active": .bool(false), "date_imprint_active": .bool(false),
        ]
        delta.merge(off) { _, new in new }
        delta[ParamDefaults.productDefaultsKey] = .bool(true)
        let openDelta = delta
        let chartFrame = DecodedFrame(pixels: FloatRGBPixels(chart), width: side, height: side)
        let photoLoads = sourceGeneration
        do {
            let bitmap = try await engine.perform { () -> RenderedBitmap in
                try chartFrame.pixels.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { throw EngineError.failed(status: -1, message: "色卡为空") }
                    _ = try engine.open(pixels: EnginePixels(data: base, width: side, height: side), params: openDelta)
                }
                try engine.solve(target: "both")
                // The chart is developed to sRGB (its delta says so): tagged so, not as the preview's P3.
                return try engine.renderBitmap(tier: "full", reprint: false, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            var chartImage = bitmap.cgImage
            if finish.isActive, let layer2 = Layer2Renderer.shared {
                chartImage = try layer2.image(try layer2.source(chartImage), finish, space: Layer2Renderer.previewSpace)
            }
            guard let cube = Self.cube(from: chartImage, n: n, tiles: tiles, block: block) else { return nil }
            cube.withUnsafeBytes { raw in
                let f = raw.bindMemory(to: Float.self)
                let mid = ((12 * n + 12) * n + 12) * 4, top = ((24 * n + 24) * n + 24) * 4
                NSLog("SpektraLab viewfinder LUT %@: grey 0.5 → %.3f %.3f %.3f, white → %.3f %.3f %.3f",
                      film, f[mid], f[mid + 1], f[mid + 2], f[top], f[top + 1], f[top + 2])
            }
            viewfinderLUTs[key] = cube
            // The chart took the engine's one session. A photo that began loading while it developed
            // (its open may have run before the chart's) gets its session back; otherwise the next
            // photo opened makes its own.
            if editingPhotoID != nil || sourceGeneration != photoLoads { reopenAndRender() } else { frame = nil }
            return cube
        } catch {
            NSLog("SpektraLab viewfinder LUT: FAILED %@", error.localizedDescription)
            return nil
        }
    }

    /// Read the developed chart's sample centres into a colour cube.
    private nonisolated static func cube(from image: CGImage, n: Int, tiles: Int, block: Int) -> Data? {
        let w = image.width, h = image.height
        guard w == tiles * n * block, h == w, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
              let raw = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = raw.assumingMemoryBound(to: UInt16.self)
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n {
            let tx = (b % tiles) * n, ty = (b / tiles) * n
            for g in 0..<n {
                for r in 0..<n {
                    // The block's centre. A bitmap context's memory starts at the image's top row, the
                    // same row order the chart was written in (flipping here read every edge colour
                    // from another block: white came back red; mid-grey, at the centre, hid it).
                    let x = (tx + r) * block + block / 2, y = (ty + g) * block + block / 2
                    let o = (y * w + x) * 4
                    let c = ((b * n + g) * n + r) * 4
                    cube[c] = Float(px[o]) / 65535; cube[c + 1] = Float(px[o + 1]) / 65535; cube[c + 2] = Float(px[o + 2]) / 65535
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// A shot with no film: the camera's own file goes into Photos as it is, and SpektraLab only
    /// links it (no copy here) so it can still be developed later.
    func addShotToPhotos(_ data: Data, isRAW: Bool) async -> UIImage? {
        guard await PhotoAssets.authorize() else {
            libraryMessage = "没有相册权限，照片没能保存"
            return nil
        }
        do {
            let uti = isRAW ? "com.adobe.raw-image" : UTType.heic.identifier
            let assetID = try await PhotoAssets.save(data, uti: uti)
            // 无胶卷: Photos only, not 底片 (open it from the 系统相册 view to develop it).
            guard let asset = PhotoAssets.asset(assetID) else { return nil }
            return await PhotoAssets.thumbnail(asset, side: LibraryThumbnail.maxPixel)
        } catch {
            libraryMessage = "照片没能存进相册：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - half-frame pairs

    /// Compose two library photographs into one half-frame piece and add it to the wall.
    /// Each is cut to an 18 × 24 hole, metered alone, and set beside the other.
    @discardableResult
    func makePair(_ spec: PairSpec) async -> UUID? {
        guard libraryBusy == nil,
              let left = library.first(where: { $0.id == spec.left }),
              let right = library.first(where: { $0.id == spec.right }) else { return nil }
        libraryBusy = "正在合成双拼…"
        defer { libraryBusy = nil }
        func upright(_ p: LibraryPhoto) -> CGSize {
            let long = CGFloat(max(p.pixelWidth, p.pixelHeight)), a = CGFloat(max(p.sourceAspect, 0.01))
            return a >= 1 ? CGSize(width: long, height: long / a) : CGSize(width: long * a, height: long)
        }
        // Each window's own height at full resolution; the taller sets the piece (capped), the other is scaled to it.
        let places = [(left, spec.leftPlace), (right, spec.rightPlace)]
        let native = places.map { p, place -> Double in
            let size = upright(p)
            return Double(PairComposer.window(place, in: size).height * size.height)
        }
        let holeHeight = min(native.max() ?? 0, 6000)
        var sources: [(Data, String?, Int, PairPlacement)] = []
        do {
            for (i, item) in places.enumerated() {
                // Decode only as large as this window needs at `holeHeight`.
                let long = Double(max(item.0.pixelWidth, item.0.pixelHeight))
                let k = min(1, holeHeight / max(native[i], 1))
                sources.append((try await originalData(for: item.0), item.0.typeIdentifier,
                                max(1, Int((long * k).rounded())), item.1))
            }
        } catch {
            libraryMessage = "双拼失败：\(error.localizedDescription)"
            return nil
        }
        let target = Int(holeHeight.rounded())
        do {
            let heif = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                var holes: [DecodedFrame] = []
                for (data, type, longEdge, place) in sources {
                    let whole = try ImageDecoder.decode(data: data, maxLongEdge: longEdge,
                                                        typeHint: type.flatMap(UTType.init))
                    let size = CGSize(width: whole.width, height: whole.height)
                    let r = PairComposer.window(place, in: size)
                    let x = Int((r.minX * size.width).rounded()), y = Int((r.minY * size.height).rounded())
                    let cut = whole.cropped(to: (x, y, min(Int((r.width * size.width).rounded()), whole.width - x),
                                                 min(Int((r.height * size.height).rounded()), whole.height - y)))
                    holes.append(PairComposer.scaled(cut, toHeight: target))
                }
                let gains = (Float(pow(2, PairComposer.meter(holes[0]) + spec.leftEV)),
                             Float(pow(2, PairComposer.meter(holes[1]) + spec.rightEV)))
                return try PairComposer.heif(PairComposer.compose(holes[0], holes[1], gains: gains))
            }.value
            let pairs = library.filter { $0.pair != nil }.count
            let id = try await addPhoto(data: heif, name: String(format: "双拼 %02d", pairs + 1), typeHint: .heic)
            if let index = library.firstIndex(where: { $0.id == id }) {
                library[index].pair = spec
                library[index].recipe = left.recipe
                saveLibraryManifest()
            }
            libraryMessage = "已生成双拼：\(left.name) + \(right.name)"
            return id
        } catch {
            libraryMessage = "双拼失败：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - crop and straighten

    /// The uncropped photograph for the crop screen.
    func cropSourceImage() -> UIImage? {
        originalData.flatMap { LibraryThumbnail.from(data: $0, maxPixel: 1600)?.0 }
    }

    /// Saved on the photo at once (not with the recipe), then the preview is re-exposed.
    func setCrop(_ new: FrameCrop) {
        guard new != crop, !exporting else { return }
        crop = new
        originalTexture = nil
        if let id = editingPhotoID, let index = library.firstIndex(where: { $0.id == id }) {
            library[index].crop = new.isIdentity ? nil : new
            library[index].isEdited = true
            saveLibraryManifest()
        }
        reloadPreviewForFilmEffect()
    }

    func setShowingOriginal(_ on: Bool) {
        guard on != showingOriginal, !(on && exporting) else { return }
        NSLog("SpektraLab original: %@", on ? "show" : "hide")
        // The button lights up even if the original cannot be decoded, so a
        // failure is not mistaken for a dead button (and is not retried per touch move).
        showingOriginal = on
        if on {
            originalTexture = originalTexture ?? makeOriginalTexture()
            guard let originalTexture else { statusText = "无法读取原图"; return }
            renderer?.setHDR(nil)          // the original as the camera wrote it, SDR
            renderer?.setTexture(originalTexture)
            renderedTexture = originalTexture
        } else {
            show(printTexture)
            renderer?.setHDR(hdrAnswer?.curve?.tables)
        }
    }

    /// Re-run only the Layer 2 pass over the cached preview; without one
    /// (Layer 2 was off) the engine renders once to make it.
    private func runLayer2() {
        guard layer2Source != nil, let layer2 = Layer2Renderer.shared else {
            if adjustments.isActive { scheduleRender() }
            return
        }
        layer2Pending = true
        guard !layer2Running else { return }
        layer2Running = true
        Task { @MainActor [weak self] in
            while let self, self.layer2Pending, let source = self.layer2Source {
                self.layer2Pending = false
                let look = self.previewAdjustments
                let frame = try? await Task.detached(priority: .userInitiated) {
                    PreviewFrame(texture: try layer2.texture(source, look), source: source,
                                 width: source.width, height: source.height, elapsedMs: 0, progressID: "")
                }.value
                // A newer engine render replaced the source meanwhile: its texture wins.
                if let frame, self.layer2Source === source {
                    self.show(frame.texture)
                }
            }
            self?.layer2Running = false
        }
    }

    // MARK: - exporting

    /// How the next export is written. Remembered between launches.
    @Published var exportOptions = ExportOptions.load() {
        didSet { if exportOptions != oldValue { exportOptions.save() } }
    }

    /// A file waiting for the share sheet (destination "文件 / 分享").
    @Published var exportedFile: ExportedFile?

    /// Export the print at the source's full resolution.
    ///
    /// The export opens its own full-size session in the chosen output space,
    /// so afterwards the preview session is reopened in sRGB: the canvas is
    /// tagged sRGB, and leaving a P3 or ProPhoto session behind would make
    /// every later preview look wrong.
    /// The long edge a full-size export can afford, nil when the original fits.
    ///
    /// Measured on the iPhone 17 Pro Max (engine 2.4.0), from about 3.1 GB free at the start:
    /// 25.6 MP succeeded; 40.7 MP (2.1 GB left once the engine held the source) and 48.8 MP
    /// (1.9 GB left) were killed in the full-size render. That is 90–100 bytes a pixel in all;
    /// 110 keeps a margin, which lands a 48 MP original at about 25 MP. A free developer account
    /// cannot ask for the larger memory limit.
    static func exportLongEdgeCap(for data: Data) -> Int? {
        guard let size = ExportWriter.pixelSize(of: data) else { return nil }
        let pixels = Double(size.width) * Double(size.height)
        let budget = Double(os_proc_available_memory()) - 400 * 1_048_576
        let affordable = max(budget, 0) / 110
        guard pixels > affordable, affordable > 0 else { return nil }
        let long = Double(max(size.width, size.height))
        return max(1024, Int(long * (affordable / pixels).squareRoot()))
    }

    /// An export holds the engine: the editor is locked and renders wait until it is done.
    @Published private(set) var exporting = false

    /// The look a print is developed with, as a key: the recipe and the crop. Equal keys = the same print.
    func exportLookKey(recipe: PhotoRecipe, crop: FrameCrop?) -> String {
        struct Look: Encodable { let recipe: PhotoRecipe; let crop: FrameCrop? }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(Look(recipe: recipe, crop: crop)).base64EncodedString()) ?? ""
    }

    /// The editor's photo already has a print in Photos: whether its look changed since. Nil when there is none
    /// (never exported, or deleted from Photos — read access permitting; without it the print is assumed there).
    func previousPrint() -> (assetID: String, changed: Bool)? {
        guard let photo = editingPhoto, let asset = photo.exportedAssetID else { return nil }
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
           PHAsset.fetchAssets(withLocalIdentifiers: [asset], options: nil).count == 0 { return nil }
        let now = exportLookKey(recipe: currentRecipe, crop: crop.isIdentity ? nil : crop)
        return (asset, photo.exportedLook != now)
    }

    /// `replacing`: a print of this photo already in Photos, moved to Recently Deleted once the new one is saved.
    func export(toPhotos: Bool = false, replacing: String? = nil) async {
        guard !exporting else { return }
        guard let engine, let originalData else {
            statusText = "还没有可导出的照片"
            return
        }
        exporting = true
        var options = exportOptions
        if toPhotos { options.destination = .photos }   // a batch never stops for a share sheet
        var failure: String?
        var doneText: String?
        state = .importing
        let started = Date()
        func stage(_ text: String) {
            statusText = "导出：\(text)"
            NSLog("SpektraLab export: %@ (%.1fs, %d MB free)", text, Date().timeIntervalSince(started),
                  Int(os_proc_available_memory() >> 20))
        }
        stage("解码原图 · \(options.format.title) · \(options.colorSpace.title)")
        var shareURL: URL?
        var reopened = false

        do {
            let data = originalData
            let hint = originalTypeHint
            let cropAspect = filmBorderEnabled ? filmCropAspect : nil
            let frameCrop = crop
            let gains = recipe.sceneBalance
            let memoryCap = Self.exportLongEdgeCap(for: data)
            if let memoryCap { NSLog("SpektraLab export: memory caps the long edge at %d px", memoryCap) }
            let noFilm = recipe.noFilm == true
            var decoded: DecodedFrame? = noFilm ? nil : try await Task.detached(priority: .userInitiated) {
                if frameCrop.isIdentity {
                    return try ImageDecoder.decode(data: data,
                                                   maxLongEdge: memoryCap ?? ImageDecoder.exportLongEdge,
                                                   typeHint: hint,
                                                   targetAspect: cropAspect).balanced(gains)
                }
                // The user's crop first, then the gate's: two full-size frames live for a moment.
                let cut = try ImageDecoder.decode(data: data, maxLongEdge: memoryCap ?? ImageDecoder.exportLongEdge,
                                                  typeHint: hint).applying(frameCrop).balanced(gains)
                return cropAspect.map { cut.centerCropped(toTargetAspect: $0) } ?? cut
            }.value
            if let decoded { stage("全尺寸渲染 \(decoded.width)×\(decoded.height)") }

            var exportDelta = currentOpenDelta()
            exportDelta["output_color_space"] = .string(options.colorSpace.engineName)
            exportDelta["output_cctf_encoding"] = .bool(true)
            // Engine 2.x: the striped executor renders the full-size frame band by band (bit-identical,
            // RFC-020 §6) and skips the disk checkpoint; unstriped, a 25 MP export was jetsam-killed mid-render.
            exportDelta["striped"] = .bool(true)
            let openDelta = exportDelta
            let space = options.colorSpace

            // 无胶片: the system's own rendering of the original stands in for the engine's print.
            var plainImage: CGImage?
            if noFilm {
                stage("原图（无胶片）")
                let tag = space.cgColorSpace ?? Layer2Renderer.previewSpace
                let edge = memoryCap ?? ImageDecoder.exportLongEdge ?? Int.max
                plainImage = try await Task.detached(priority: .userInitiated) {
                    try Self.plainPicture(data, maxLongEdge: edge, crop: frameCrop, space: tag, typeHint: hint)
                }.value
            }
            // The engine copies the pixels it keeps during `open`, so the float frame (~600 MB at
            // 48 MP) is let go right after it, before the full-size render needs the room.
            if !noFilm { try await engine.perform { [full = decoded!] in
                try full.pixels.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else {
                        throw EngineError.failed(status: -1, message: "解码结果为空")
                    }
                    _ = try engine.open(pixels: EnginePixels(
                        data: base,
                        width: full.width,
                        height: full.height), params: openDelta)
                }
            }
            }
            decoded = nil
            if !noFilm { stage("引擎已载入原图") }
            var rendered: RenderedBitmap? = noFilm ? nil : try await engine.perform {
                try engine.solve(target: "both")
                let bitmap = try engine.renderBitmap(tier: "full", reprint: false,
                                                     colorSpace: space.cgColorSpace)
                // The striped render's working buffers stay pooled; let them go before the copy below.
                let freed = engine.trimPool()
                NSLog("SpektraLab export: trimmed %d MB from the engine pool", freed >> 20)
                return bitmap
            }
            // Enable HDR: the export session's own curve (the same medium as the page's), asked on its queue.
            var hdrCurve: HDRSessionCurve?
            if !noFilm, recipe.hdr == true, options.format == .jpeg || options.format == .heif, HDRGainMap.supported {
                hdrCurve = try? HDRSessionCurve.parse(await engine.perform { try engine.hdrCurve() })
                NSLog("SpektraLab export: HDR curve %@", hdrCurve == nil ? "refused" : "ok")
            }

            var cgImage = plainImage ?? rendered!.cgImage
            let bitmap = (width: cgImage.width, height: cgImage.height)
            plainImage = nil
            // Memory (iPhone, 25 MP): the full-size session holds ~1.8 GB until the engine
            // reopens. Copy the print out (16-bit, ~200 MB), let the session go back to the
            // small preview one, and only then run 后期 and encode — with all of it held at
            // once the app was killed while encoding.
            if let layer2 = Layer2Renderer.shared {
                stage("复制成片")
                let tag = space.cgColorSpace ?? Layer2Renderer.previewSpace
                let engineImage = cgImage
                var copy: Layer2Source? = try await Task.detached(priority: .userInitiated) {
                    try layer2.source(engineImage, space: tag)
                }.value
                cgImage = try Layer2Renderer.image(of: copy!, space: tag)
                rendered = nil
                decoded = nil
                stage("释放全尺寸会话")
                if let frame { try await loadFrame(frame); reopened = true }
                let look = adjustments
                if look.isActive {
                    stage("后期")
                    let source = copy!
                    cgImage = try await Task.detached(priority: .userInitiated) {
                        try layer2.image(source, look, space: tag, midGrey: space.midGrey)
                    }.value
                }
                copy = nil
            }
            let marks = watermarkShelf.resolved(recipe.watermarks)
            if !marks.isEmpty {
                stage("水印")
                let picture = cgImage
                cgImage = await Task.detached(priority: .userInitiated) { Watermark.composite(picture, marks) }.value
            }
            stage("编码 \(options.format.title) \(bitmap.width)×\(bitmap.height)")
            let source: Data? = options.keepMetadata ? data : nil
            var gainMap: HDRGainMap.Attachment?
            if isSlideHDR, reopened, options.format == .jpeg || options.format == .heif, HDRGainMap.supported,
               let engine = self.engine {
                // A slide: the ratio of its two renditions on the (reopened) preview session, at the preview's size.
                stage("HDR 增益图（反转片）")
                if let pair = try? await engine.perform({ () -> (CGImage, CGImage) in
                    let s = try engine.renderBitmap(tier: "live", reprint: true).cgImage
                    _ = try engine.setParams(HDRSlide.renditionDelta)
                    defer { _ = try? engine.setParams(HDRSlide.restoreDelta) }
                    return (s, try engine.renderBitmap(tier: "live", reprint: true).cgImage)
                }) {
                    gainMap = await Task.detached(priority: .userInitiated) {
                        HDRSlide.gainPlane(sdr: pair.0, hdr: pair.1).flatMap(HDRSlide.attachment)
                    }.value
                }
            }
            if gainMap == nil, let hdrCurve {
                stage("HDR 增益图")
                let picture = cgImage
                gainMap = await Task.detached(priority: .userInitiated) { HDRExport.attachment(for: picture, curve: hdrCurve) }.value
            }
            let url = try await Self.write(cgImage, options: options, source: source, gainMap: gainMap)
            if let map = gainMap, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                NSLog("SpektraLab export: gain map %dx%d written %@, depth %@", map.map.width, map.map.height,
                      HDRGainMap.present(in: src) ? "yes" : "NO", String(describing: props?[kCGImagePropertyDepth] ?? "?"))
            }

            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let estimate = exportEstimate, estimate.options.format == options.format,
               estimate.options.quality == options.quality, let raw = estimate.rawBytes {
                ExportCalibration.record(actual: Int64(bytes), raw: raw, format: options.format)
            }
            let megabytes = Double(bytes) / 1_048_576
            switch options.destination {
            case .photos:
                stage("保存到相册")
                let assetID = try await PhotoLibrary.saveImage(at: url)
                if let id = editingPhotoID, let i = library.firstIndex(where: { $0.id == id }) {
                    library[i].exportedAt = Date()
                    if let assetID {
                        library[i].exportedAssetID = assetID
                        library[i].exportedLook = exportLookKey(recipe: recipe, crop: crop.isIdentity ? nil : crop)
                    }
                    saveLibraryManifest()
                }
                if let replacing, replacing != assetID {
                    stage("删除旧成片")
                    _ = await PhotoLibrary.deleteAsset(replacing)
                }
                doneText = String(format: "已导出 %d×%d · %.1f MB 到相册",
                                  bitmap.width, bitmap.height, megabytes) + (memoryCap == nil ? "" : "（内存不够，已缩小）")
            case .files:
                shareURL = url
                doneText = String(format: "已生成 %d×%d · %.1f MB",
                                  bitmap.width, bitmap.height, megabytes) + (memoryCap == nil ? "" : "（内存不够，已缩小）")
            }
            NSLog("SpektraLab export: done in %.1fs", Date().timeIntervalSince(started))
        } catch {
            failure = error.localizedDescription
            NSLog("SpektraLab export: FAILED %@", failure ?? "")
        }

        if let failure {
            state = .failed(failure)
            statusText = "导出失败"
        } else if let doneText {
            state = .ready
            statusText = doneText
        }
        // Back to the sRGB preview session, the same way a film change does.
        // Without it the next preview would come from the full-size export
        // session in the export's colour space.
        NSLog("SpektraLab export: reopening preview session")
        exporting = false
        if !reopened { reopenAndRender() }
        if let shareURL {
            let file = ExportedFile(url: shareURL)
            exportedFile = file
            ShareController.present(url: shareURL) { [weak self] in
                self?.finishSharing(file)
            }
        }
    }

    // MARK: - export size estimate

    @Published private(set) var exportEstimate: ExportEstimate?
    private var estimateTask: Task<Void, Never>?
    private var estimatePreview: (identity: String, image: CGImage)?

    /// The pixel size the export will have: the original's full size, cut to
    /// the film gate when the film edge is on, exactly as `export()` decodes.
    /// The size the export will really have: crop, film gate, and the memory cap.
    private func exportPixelSize() -> (width: Int, height: Int)? {
        guard let originalData,
              let original = ExportWriter.pixelSize(of: originalData) else { return nil }
        var full = original
        // The decoder scales the source to the cap before the crop and the gate cut it.
        if let cap = Self.exportLongEdgeCap(for: originalData) {
            let k = Double(cap) / Double(max(original.width, original.height))
            full = (Int((Double(original.width) * k).rounded()), Int((Double(original.height) * k).rounded()))
        }
        let size = crop.outputSize(source: CGSize(width: full.width, height: full.height))
        guard filmBorderEnabled else { return size }
        let crop = ImageDecoder.centerCrop(width: size.width, height: size.height,
                                           targetAspect: filmCropAspect)
        return (crop.width, crop.height)
    }

    /// The original's own pixel count when the memory cap makes the export smaller, else nil.
    var exportCappedFromMegapixels: Double? {
        guard let originalData, Self.exportLongEdgeCap(for: originalData) != nil,
              let o = ExportWriter.pixelSize(of: originalData) else { return nil }
        return Double(o.width * o.height) / 1_000_000
    }

    /// Re-estimate for the current options. Encodes the live preview with the
    /// chosen format and quality and scales the bytes by pixel count.
    func refreshExportEstimate() {
        estimateTask?.cancel()
        guard let engine, let size = exportPixelSize() else {
            exportEstimate = nil
            return
        }
        let options = exportOptions
        exportEstimate = ExportEstimate(width: size.width, height: size.height, options: options)
        let identity = renderIdentity
        estimateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            let preview: CGImage
            if let cached = self.estimatePreview, cached.identity == identity {
                preview = cached.image
            } else {
                guard let bitmap = try? await engine.perform({
                    try engine.renderBitmap(tier: "live", reprint: true)
                }) else { return }
                self.estimatePreview = (identity, bitmap.cgImage)
                preview = bitmap.cgImage
            }
            guard !Task.isCancelled else { return }
            let sampleBytes = await Task.detached(priority: .userInitiated) {
                ExportWriter.encodedSize(preview, options: options)
            }.value
            guard !Task.isCancelled, let sampleBytes, sampleBytes > 0 else { return }
            let samplePixels = Double(preview.width * preview.height)
            let raw = Int64(Double(sampleBytes) * Double(size.width * size.height) / samplePixels)
            let factor = ExportCalibration.factor(for: options.format)
            var estimate = ExportEstimate(width: size.width, height: size.height, options: options)
            estimate.rawBytes = raw
            estimate.bytes = Int64(Double(raw) * (factor ?? 1))
            estimate.calibrated = factor != nil
            if self.exportOptions == options {
                self.exportEstimate = estimate
            }
        }
    }

    /// The share sheet closed; the temporary file is no longer needed.
    func finishSharing(_ file: ExportedFile) {
        try? FileManager.default.removeItem(at: file.url)
        if exportedFile?.id == file.id { exportedFile = nil }
    }

}

/// Encoding, off the main actor.
enum ExportWriter {
    nonisolated static func write(_ cgImage: CGImage, options: ExportOptions,
                                  sourceData: Data?, gainMap: HDRGainMap.Attachment? = nil) throws -> URL {
        let stamp = Self.fileStamp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpektraCam_\(stamp).\(options.format.fileExtension)")
        try? FileManager.default.removeItem(at: url)
        let metadata = sourceData.flatMap { Self.metadata(from: $0) } ?? [:]

        // Enable HDR: ImageIO, which takes the gain map beside the picture (Core Image's 10-bit HEIF writer does not).
        let viaImageIO = gainMap != nil && (options.format == .heif || options.format == .jpeg)
        switch options.format {
        case .heif where !viaImageIO:
            try writeHEIF10(cgImage, to: url, options: options, metadata: metadata)
        case .heif, .jpeg, .tiff16, .png:
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, options.format.utType.identifier as CFString, 1, nil) else {
                throw ExportError.encodingFailed
            }
            var properties = metadata
            switch options.format {
            case .jpeg, .heif:
                properties[kCGImageDestinationLossyCompressionQuality] = options.quality
            case .tiff16:
                var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                tiff[kCGImagePropertyTIFFCompression] = 5   // LZW
                properties[kCGImagePropertyTIFFDictionary] = tiff
            case .png:
                break
            }
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            if viaImageIO, let gainMap { try HDRGainMap.attach(gainMap, to: destination) }
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: url)
                throw ExportError.encodingFailed
            }
        }
        return url
    }

    /// The encoded size of `cgImage` with these options, in memory, without
    /// metadata. Used for the size estimate.
    nonisolated static func encodedSize(_ cgImage: CGImage, options: ExportOptions) -> Int? {
        switch options.format {
        case .heif:
            guard let space = options.colorSpace.cgColorSpace else { return nil }
            let context = CIContext(options: [.cacheIntermediates: false])
            let ciOptions: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
                    options.quality
            ]
            let data: Data? = try? context.heif10Representation(of: CIImage(cgImage: cgImage),
                                                                colorSpace: space,
                                                                options: ciOptions)
            return data?.count
        case .jpeg, .tiff16, .png:
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, options.format.utType.identifier as CFString, 1, nil) else {
                return nil
            }
            var properties: [CFString: Any] = [:]
            if options.format == .jpeg {
                properties[kCGImageDestinationLossyCompressionQuality] = options.quality
            } else if options.format == .tiff16 {
                properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
            }
            var image = cgImage
            // The preview is 8-bit; a 16-bit TIFF of it would be half the size
            // of the real one. Widen it so the estimate counts 16 bits.
            if options.format == .tiff16 || options.format == .png, cgImage.bitsPerComponent < 16,
               let widened = widen16(cgImage) {
                image = widened
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data.length
        }
    }

    private nonisolated static func widen16(_ image: CGImage) -> CGImage? {
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                        | CGBitmapInfo.byteOrder16Little.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// The original file's pixel size, upright.
    nonisolated static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// 10-bit HEIF through Core Image; ImageIO's HEIC writer is 8-bit only.
    private nonisolated static func writeHEIF10(_ cgImage: CGImage, to url: URL,
                                                options: ExportOptions,
                                                metadata: [CFString: Any]) throws {
        guard let space = cgImage.colorSpace ?? options.colorSpace.cgColorSpace else {
            throw ExportError.encodingFailed
        }
        var image = CIImage(cgImage: cgImage)
        if !metadata.isEmpty {
            let props = Dictionary(uniqueKeysWithValues:
                metadata.map { (AnyHashable($0.key as String), $0.value) })
            image = image.settingProperties(props)
        }
        let context = CIContext(options: [.workingColorSpace: space,
                                          .cacheIntermediates: false])
        let ciOptions: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
                options.quality
        ]
        do {
            try context.writeHEIF10Representation(of: image, to: url,
                                                  colorSpace: space, options: ciOptions)
        } catch {
            throw ExportError.encodingFailed
        }
    }

    /// EXIF, GPS and the camera's make and model from the original file.
    /// The pixels are already upright, so the orientation is reset, and the
    /// source's dimensions are dropped so they cannot contradict the print's.
    nonisolated static func metadata(from data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        var out: [CFString: Any] = [:]
        if var exif = all[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            out[kCGImagePropertyExifDictionary] = exif
        }
        if let gps = all[kCGImagePropertyGPSDictionary] {
            out[kCGImagePropertyGPSDictionary] = gps
        }
        if let aux = all[kCGImagePropertyExifAuxDictionary] {
            out[kCGImagePropertyExifAuxDictionary] = aux
        }
        var tiff: [CFString: Any] = [:]
        if let srcTIFF = all[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
                        kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist,
                        kCGImagePropertyTIFFCopyright] {
                if let value = srcTIFF[key] { tiff[key] = value }
            }
        }
        tiff[kCGImagePropertyTIFFSoftware] = "Spektra Cam"
        tiff[kCGImagePropertyTIFFOrientation] = 1
        out[kCGImagePropertyTIFFDictionary] = tiff
        out[kCGImagePropertyOrientation] = 1
        return out
    }

    private nonisolated static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

/// RAW 原始文件字节（ARW/CR3/DNG…）。优先按 `rawImage` 取原始数据；普通照片
/// 回退到 `image`。`PhotosPickerItem.loadTransferable(type: Data.self)` 对于
/// RAW 只能拿到渲染后的位图，拿不到原始字节，所以这里用自定义 Transferable。
///
/// The `importedContentType:` label is the one this SDK expects; the older
/// `importedAs:` is not a parameter of `DataRepresentation` any more, and
/// writing it is a compile error rather than a deprecation.
struct PickedImageData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .rawImage) { Self(data: $0) }
        DataRepresentation(importedContentType: .image) { Self(data: $0) }
    }
}

/// Saving to the photo library, with the permission the app needs.
enum PhotoLibrary {
    /// Ask for permission and save. Photos keeps JPEG, HEIF and TIFF as they are.
    /// Saves the file into Photos and returns the new asset's id (nil if Photos did not say).
    @discardableResult
    static func saveImage(at url: URL) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.permissionDenied
        }
        defer { try? FileManager.default.removeItem(at: url) }
        final class Box: @unchecked Sendable { var id: String? }
        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
            box.id = request.placeholderForCreatedAsset?.localIdentifier
        }
        return box.id
    }

    /// Moves a print to Photos' Recently Deleted (iOS asks the person first). False if refused or gone.
    static func deleteAsset(_ id: String) async -> Bool { await deleteAssets([id]) > 0 }

    /// Moves pictures to Photos' Recently Deleted (iOS asks first): how many, 0 if none were found, -1 if refused.
    /// Nonisolated on purpose: Photos calls the change block on its own queue (see `deleteFromPhotos`).
    nonisolated static func deleteAssets(_ ids: [String]) async -> Int {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard found.count > 0 else { return 0 }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(found) }
            return found.count
        } catch { return -1 }
    }
}

enum ExportError: Error, CustomStringConvertible {
    case permissionDenied
    case encodingFailed
    var description: String {
        switch self {
        case .permissionDenied: "没有相册写入权限，请在系统设置里允许"
        case .encodingFailed: "照片编码失败，无法导出"
        }
    }
}

/// What the preview shows: the engine's texture, or Layer 2's over the engine's bitmap.
private struct PreviewFrame: @unchecked Sendable {
    let texture: MTLTexture?
    let source: Layer2Source?
    let width: Int
    let height: Int
    let elapsedMs: Double
    let progressID: String
}
