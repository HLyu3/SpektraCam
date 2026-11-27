//  LightTablePane.swift — 观片台: this app's page round upstream's light table (`LightTableController`,
//  `LightTableView`, `LightTableGestures`, all upstream's). Written for this app, after upstream's
//  `LightTablePane` (whose page is the Mac's now): top bar ‹ 观片台 ···, the table, a status line with
//  Undo for 6 s, and a row of actions — at rest 添加 · 放大镜 · 适合 · 纸张 · 方向; with a film chosen
//  转 90° · 拉近 · 拿走.

import SwiftUI
import UniformTypeIdentifiers
import ImageIO

extension ViewModel {
    /// Every photo of the library as the light table reads it.
    var lightTableFrames: [LibraryFrame] {
        let print = UserDefaults.standard.object(forKey: Self.lightTablePrintKey) as? Bool ?? false
        let scales = UserDefaults.standard.dictionary(forKey: Self.lightTableScalesKey) as? [String: Double] ?? [:]
        return library.map { p in
            let url = thumbnailURL(for: p.id)
            let base = LightTableFrames.sizeMM(of: p, print: print)
            let k = scales[p.id.uuidString] ?? 1
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return LibraryFrame(id: p.id, sizeMM: CGSize(width: base.width * k, height: base.height * k), thumbnail: url,
                                large: largeDevelopURL(for: p.id), stamp: stamp,
                                caption: filmName(for: p.recipe.filmID))
        }
    }

    var lightTableStoreURL: URL { libraryRootURL.appendingPathComponent(LightTableStore.fileName) }

    /// Films lie at print size (true) or as the negative (false).
    static let lightTablePrintKey = "SpektraLab.lightTablePrint"
    /// Each film's own scale from a pinch, by photo id.
    static let lightTableScalesKey = "SpektraLab.lightTableScales"

    /// A film's pinch scale (1 when it has none).
    func lightTableScale(_ id: UUID) -> Double {
        (UserDefaults.standard.dictionary(forKey: Self.lightTableScalesKey) as? [String: Double])?[id.uuidString] ?? 1
    }

    /// Forget the pinch scales of these films, or of all.
    func resetLightTableScales(_ ids: [UUID]?) {
        NSLog("SpektraLab lighttable: reset scales %@", ids.map { "\($0.count)" } ?? "all")
        guard let ids else { UserDefaults.standard.removeObject(forKey: Self.lightTableScalesKey); return }
        var scales = UserDefaults.standard.dictionary(forKey: Self.lightTableScalesKey) as? [String: Double] ?? [:]
        for id in ids { scales[id.uuidString] = nil }
        UserDefaults.standard.set(scales, forKey: Self.lightTableScalesKey)
    }

    /// A pinch ended: the film's scale against its base size, kept for next time.
    func setLightTableSize(_ id: UUID, _ size: CGSize) {
        guard let p = library.first(where: { $0.id == id }) else { return }
        let print = UserDefaults.standard.object(forKey: Self.lightTablePrintKey) as? Bool ?? false
        let base = LightTableFrames.sizeMM(of: p, print: print)
        var scales = UserDefaults.standard.dictionary(forKey: Self.lightTableScalesKey) as? [String: Double] ?? [:]
        scales[id.uuidString] = Double(size.width / max(base.width, 0.01))
        UserDefaults.standard.set(scales, forKey: Self.lightTableScalesKey)
        NSLog("SpektraLab lighttable: scale %@ = %.3f (size %.1f, base %.1f)", id.uuidString, scales[id.uuidString] ?? 0,
              size.width, base.width)
    }

    /// The 2048 px develop kept beside the thumbnail for the light table and the slide show.
    func largeDevelopURL(for id: UUID) -> URL { libraryRootURL.appendingPathComponent("\(id.uuidString)-large.jpg") }

    /// That develop, made now if missing or older than the thumbnail. Nil while the engine is busy elsewhere.
    /// The large develop's long edge: past the phone screen's own pixels (2868 on a 17 Pro Max), so a full-screen
    /// photo in the viewer is not upscaled. It was 2048, which the owner saw as soft.
    static let largeDevelopEdge = 3072

    /// The kept large develop, if it is current (no newer thumbnail, i.e. the look has not changed since) — never made.
    func keptLargeDevelop(for id: UUID) -> UIImage? {
        let url = largeDevelopURL(for: id)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let thumb = (try? thumbnailURL(for: id).resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
        guard let made = (try? url.resourceValues(forKeys: keys))?.contentModificationDate, made >= thumb,
              let image = UIImage(contentsOfFile: url.path),
              max(image.size.width, image.size.height) * image.scale >= CGFloat(Self.largeDevelopEdge) - 8 else { return nil }
        DevelopCache.touch(url)
        return image
    }

    func largeDevelop(for id: UUID) async -> UIImage? {
        let url = largeDevelopURL(for: id)
        if let kept = keptLargeDevelop(for: id) { return kept }
        guard let image = await slideImage(for: id, longEdge: Self.largeDevelopEdge) else { return nil }
        if let data = image.jpegData(compressionQuality: 0.9) { try? data.write(to: url, options: .atomic) }
        return image
    }
}

/// Makes the films' large develops one at a time, as the table asks for them, and tells it when one lands.
@MainActor
final class LargeDevelops {
    private var queue: [UUID] = []
    private var running = false
    weak var table: LightTableController?
    let model: ViewModel
    init(model: ViewModel) { self.model = model }

    func want(_ ids: Set<UUID>) {
        want(ordered: ids.sorted(by: { $0.uuidString < $1.uuidString }))
    }

    /// In this order (the table's films first, then the tray's), each once.
    /// Leaving the light table: nothing more is made in the background.
    func stop() { queue.removeAll() }

    func want(ordered ids: [UUID]) {
        for id in ids where !queue.contains(id) { queue.append(id) }
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let id = queue.removeFirst()
        let onTable = table?.model.order.contains(id) ?? false
        if onTable { table?.setMaking([id: -1]) }
        Task { @MainActor in
            let made = await model.largeDevelop(for: id) != nil
            running = false
            if onTable { table?.setMaking([:]) }
            if made { if onTable { table?.rendersChanged() } } else { queue.removeAll() }      // engine busy: asked again later
            pump()
        }
    }
}

struct LightTablePane: View {
    @ObservedObject var model: ViewModel
    /// Laid down when the page opens (the wall's selection).
    var laying: [UUID] = []
    /// A tab of its own (`MainTabs`): no back button.
    var embedded = false
    /// Back, when the page is not presented (pushed by `MainTabs`); nil = dismiss.
    var close: (() -> Void)? = nil
    /// False while the page waits off screen (`MainTabs` keeps it built).
    var active = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var table: LightTableController?
    @State private var tableClosed = false
    @State private var loupeMode = false
    @State private var adding = false
    @State private var undo: Undo?
    /// The backlight past white, linear: 1 标准, 2 明亮, 4 最亮 (capped at what the screen can show).
    @AppStorage("SpektraLab.lightTableGlow") private var glow = 2.0
    @AppStorage("SpektraLab.lightTableEDR") private var edr = true
    @AppStorage("SpektraLab.lightTableLoupe") private var loupeMag = 3.0
    @State private var lampOn = true
    @State private var showing = false
    /// The film a long press opened full screen (nil: the slide show from the first).
    @State private var showingFrom: UUID?
    @State private var largeDevelops: LargeDevelops?
    /// The film tray: the library's photos not on the table, along the bottom, to tap or drag onto it.
    @State private var trayOpen = false
    /// Films as the negative (default, the table's own scale) or at print size (a 5-inch print).
    @AppStorage(ViewModel.lightTablePrintKey) private var printSize = false

    private struct Undo: Equatable {
        var kept: LightTableModel
        var text: String
        var token = UUID()
    }

    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
    private var count: Int { table?.model.order.count ?? 0 }

    var body: some View {
        let immersive = table?.immersive ?? false
        VStack(spacing: 0) {
            topBar.opacity(immersive ? 0 : 1)
            tableArea
            band.opacity(immersive ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.2), value: immersive)
        // The tab bar is covered by `MainTabs` (black over it), not hidden: hiding it re-laid the page out under the
        // finger, which dropped the big lens a moment after it opened and left the table stuck until the finger lifted.
        .onChange(of: immersive) { _, on in model.lightTableImmersive = on }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // Open while shown; off screen the background develops stop at once (the engine is the editor's), the table
        // itself closes after 30 s (its textures) — coming back sooner finds it as it was.
        .task(id: active) {
            if active { open(); return }
            largeDevelops?.stop()
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled, !tableClosed { table?.close(); tableClosed = true }
        }
        .onDisappear { if !tableClosed { table?.close(); tableClosed = true }; largeDevelops?.stop() }
        .onChange(of: glow) { _, _ in applyGlow() }
        .onChange(of: printSize) { _, on in
            guard let table else { return }
            table.sync(model.lightTableFrames)
            // The films changed size where they lay: spread them out again so they don't pile up.
            if count > 1 { arrange(String(localized: "随机摆放")) { $0.random() } }
        }
        .onChange(of: edr) { _, _ in applyGlow() }
        .onChange(of: loupeMag) { _, m in
            LightTable.mag = m
            if loupeMode, let t = table { t.loupe(at: t.loupeCentre) }      // redrawn at the new power
        }
        .onChange(of: model.library.map(\.id)) { _, _ in table?.sync(model.lightTableFrames) }
        .fullScreenCover(isPresented: $showing) {
            LightTableSlideShow(model: model, ids: table?.model.order ?? [], start: showingFrom)
        }
        .sheet(isPresented: $adding) {
            LightTableAddSheet(model: model, onTable: Set(table?.model.order ?? []),
                               room: max(0, LightTable.films - count)) { layDown($0) }
        }
    }

    private func open() {
        if let table {
            // Still open (back within 30 s): only the develops restart. Closed: reopen (it watches memory again).
            if tableClosed { table.reopen(model.lightTableFrames); tableClosed = false }
            sharpen(table)
            return
        }
        let c = LightTableController(frames: model.lightTableFrames, bodySeed: 0,
                                     store: LightTableStore(url: model.lightTableStoreURL))
        c.select(nil)
        let develops = LargeDevelops(model: model)
        develops.table = c
        largeDevelops = develops
        c.fullRender = { LightTableFullRead.ref($0) }
        c.canMakeFull = { _ in true }
        c.wantsFull = { develops.want($0) }
        c.onResized = { [model] id, size in model.setLightTableSize(id, size) }
        c.glow = lampGlow
        c.prints = true      // films cover what is under them (the owner: overlapping films occlude), at any size
        LightTable.mag = loupeMag
        table = c
        sharpen(c)
        if !laying.isEmpty {
            // A moment after, so the view has its size and the free spots are its.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                layDown(laying)
            }
        }
    }

    /// Every film gets its large develop (3072 px), made one at a time in the background and kept on disk: the
    /// table's films first, then the tray's, so a film dragged on is sharp as it lands (it was soft, then sharpened
    /// a moment later). The table and its loupe read it rather than the 900 px thumbnail.
    private func sharpen(_ c: LightTableController) {
        let onTable = c.model.order
        let rest = model.lightTableFrames.map(\.id).filter { !onTable.contains($0) }
        largeDevelops?.want(ordered: onTable + rest)
    }

    // MARK: top bar

    private var topBar: some View {
        HStack {
            if embedded {
                Text(String(localized: "观片台")).font(.system(size: 28, weight: .bold)).padding(.leading, 8)
                Spacer()
            } else {
                // A glass capsule naming where it goes (a bare chevron was small and hard to hit; no edge swipe — the
                // owner preferred a button that is easy to press).
                Button { if let close { close() } else { dismiss() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                        Text(String(localized: "底片")).font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Color.labCream)
                    .padding(.leading, 12).padding(.trailing, 16)
                    .frame(height: 44)
                    .labGlassInteractive(in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "返回底片"))
                Spacer()
                Text(String(localized: "观片台")).font(.headline)
                Spacer()
            }
            if loupeMode {
                HStack(spacing: 2) {
                    ForEach([2.0, 3.0, 5.0, 8.0], id: \.self) { m in
                        Button { loupeMag = m } label: {
                            Text("\(Int(m))×").font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(loupeMag == m ? Color.black : Color.labCream)
                                .frame(width: 34, height: 28)
                                .background(loupeMag == m ? Color.labCream : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            Button { showingFrom = nil; showing = true } label: {
                Image(systemName: "play.rectangle").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 44)
            }
            .disabled(count == 0)
            .accessibilityLabel(String(localized: "幻灯"))
            Menu {
                // Short at the top level: the photos' size first (the thing most changed), the rest in submenus.
                Menu {
                    Picker(String(localized: "照片尺寸"), selection: $printSize) {
                        Text(String(localized: "底片实际尺寸")).tag(false)
                        Text(String(localized: "相片尺寸（5 寸）")).tag(true)
                    }
                    Button { resetSizes() } label: { Label(String(localized: "全部恢复原大小"), systemImage: "arrow.uturn.backward") }
                } label: { Label(String(localized: "照片尺寸"), systemImage: "photo") }
                Menu {
                    Toggle(isOn: $edr) { Label(String(localized: "EDR 背光"), systemImage: "sun.max") }
                    Picker(String(localized: "背光亮度"), selection: $glow) {
                        Text(String(localized: "标准")).tag(1.0)
                        Text(String(localized: "明亮")).tag(2.0)
                        Text(String(localized: "最亮")).tag(4.0)
                    }
                    .disabled(!edr)
                } label: { Label(String(localized: "背光"), systemImage: "sun.max") }
                Menu {
                    Picker(String(localized: "纸张"), selection: Binding(get: { table?.model.paper ?? .a4 }, set: { setTable(paper: $0) })) {
                        ForEach(LightTablePaper.allCases) { paper in
                            Text("\(paper.name)（\(Int(paper.size.width))×\(Int(paper.size.height)) mm）").tag(paper)
                        }
                    }
                    Button { setTable(portrait: !(table?.model.portrait ?? true)) } label: {
                        Label((table?.model.portrait ?? true) ? String(localized: "转成横向") : String(localized: "转成竖向"), systemImage: "rectangle.portrait.rotate")
                    }
                    Button { table?.fit() } label: { Label(String(localized: "适合屏幕"), systemImage: "arrow.down.right.and.arrow.up.left") }
                } label: { Label(String(localized: "灯箱"), systemImage: "rectangle.portrait") }
                Button { exportTable() } label: { Label(String(localized: "导出观片台…"), systemImage: "square.and.arrow.up") }
                    .disabled(count == 0)
                Divider()
                Group {
                Button { arrange(String(localized: "排整齐")) { $0.tidyUp($0.model.order) } } label: { Label(String(localized: "排整齐"), systemImage: "square.grid.3x3") }
                Button { arrange(String(localized: "随机摆放")) { $0.random() } } label: { Label(String(localized: "随机摆放"), systemImage: "shuffle") }
                Button { arrange(String(localized: "打乱")) { $0.scatter() } } label: { Label(String(localized: "打乱"), systemImage: "rectangle.on.rectangle.angled") }
                Divider()
                Button(role: .destructive) { arrange(String(localized: "全部拿走")) { $0.removeAll() } } label: { Label(String(localized: "全部拿走"), systemImage: "trash") }
                }
                .disabled(count == 0)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel(String(localized: "更多"))
        }
        .foregroundStyle(Color.labCream)
        .padding(.horizontal, 8)
    }

    // MARK: the table

    @ViewBuilder private var tableArea: some View {
        if let table {
            ZStack(alignment: .top) {
                LightTableView(controller: table, inset: .init(top: 10, left: 10, bottom: 10, right: 10)) { view in
                    view.ringColor = LightTableMetalView.ringWhite
                    LightTableGestures.attach(to: view, loupeMode: { loupeMode })
                    // This app: with the loupe tool on, a long press is the immersive loupe (upstream has no long press).
                    // Off, a long press does nothing of its own (the owner: it magnified without the loupe chosen).
                    LongPressOpen.attach(to: view, enabled: { loupeMode }) { p in
                        if let p {
                            let opening = !LightTable.bigLens
                            if opening { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                            table.immersiveLoupe(at: p)
                            // The big lens leans in to 8× (the owner: the hold is for a close look). The table's own
                            // lean timer never fired here: this press cancels its gesture as it begins.
                            if opening { table.loupeLean(true, fromPress: true) }
                        } else {
                            table.loupeLean(false, fromPress: true)       // back to the loupe's own power on lifting
                            // With the loupe tool on, its lens stays where the finger lifted (it jumped to the middle).
                            table.immersiveLoupe(at: nil, keep: loupeMode)
                        }
                    }
                    view.describe = { id in (table.caption(id), "") }
                    view.activate = { id in
                        if table.selected == id { table.select(nil) } else { table.select(id); table.bringToTop(id) }
                    }
                    view.escape = { table.select(nil) }
                }
                .clipped()
                .dropDestination(for: String.self) { items, location in
                    let ids = items.compactMap(UUID.init(uuidString:))
                    guard !ids.isEmpty else { return false }
                    undo = nil
                    table.add(ids.filter { !table.model.order.contains($0) }, at: table.viewport.toWorld(location))
                    return true
                }
                if table.model.order.isEmpty && !trayOpen {
                    Button { withAnimation(.snappy(duration: 0.25)) { trayOpen = true } } label: {
                        Label(String(localized: "从图库添加"), systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 20).frame(height: 46)
                            .labGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.labCream)
                    .frame(maxHeight: .infinity)
                }
                // A loupe standing on the film where the finger is, as on a real light table; the magnified view
                // is the lens held above it.
                if let p = table.loupeStand, !table.immersive {
                    let r = table.loupeFootRadius(power: loupeMag)
                    GeometryReader { _ in
                        LoupeModel(radius: r)
                            .frame(width: r * 2 + 24, height: r * 2 + 24)
                            .position(p)                             // standing on the film where the finger is
                            .allowsHitTesting(false)
                    }
                    .transition(.opacity)
                }
                if let angle = table.turningAngle {
                    Text(angle)
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 11).frame(height: 28)
                        .background(Color.labPanel.opacity(0.86), in: Capsule())
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
            // The tray floats over the table's foot rather than taking room from it: resizing the Metal view on every
            // frame of the slide-in made opening it stutter.
            .overlay(alignment: .bottom) {
                if trayOpen && table.selected == nil && !table.immersive {
                    tray
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            }
        } else {
            Color.clear
        }
    }

    // MARK: the band

    private var band: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if undo != nil {
                    Button(String(localized: "撤销")) { undoNow() }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
            }
            .frame(height: 28)
            HStack(spacing: 10) {
                if let table, let id = table.selected {
                    action(String(localized: "转 90°"), "rotate.left") { table.turnQuarter(id) }
                    action(String(localized: "拉近"), "plus.magnifyingglass") { table.zoomToFilm(id) }
                    action(String(localized: "拿走"), "tray.and.arrow.up") {
                        let kept = table.snapshot(), name = table.caption(id)
                        table.remove(id)
                        offerUndo(kept, String(localized: "拿走了 · ") + name)
                    }
                    if model.lightTableScale(id) != 1 {
                        action(String(localized: "原大小"), "arrow.uturn.backward") { resetSizes([id]) }
                    } else {
                        action(String(localized: "完成"), "checkmark") { table.select(nil) }
                    }
                } else {
                    action(String(localized: "胶片托盘"), "tray", lit: trayOpen) {
                        if loupeMode { toggleLoupe() }
                        withAnimation(.snappy(duration: 0.25)) { trayOpen.toggle() }
                    }
                    action(lampOn ? String(localized: "关灯") : String(localized: "开灯"), lampOn ? "lightbulb.fill" : "lightbulb.slash", lit: !lampOn) { toggleLamp() }
                    action(String(localized: "放大镜"), "magnifyingglass", lit: loupeMode) { toggleLoupe() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .foregroundStyle(Color.labCream)
    }

    /// The film tray: photos not on the table, newest first. A tap lays one in the middle; a drag lays it where it is
    /// dropped; the grid at the end picks several at once.
    private var tray: some View {
        let onTable = Set(table?.model.order ?? [])
        let waiting = model.library.filter { !onTable.contains($0.id) }
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                if waiting.isEmpty {
                    Text(String(localized: "图库里的照片都在台上了")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                ForEach(waiting) { photo in
                    Image(uiImage: photo.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { layDown([photo.id]) }
                        .draggable(photo.id.uuidString) {
                            Image(uiImage: photo.thumbnail).resizable().scaledToFit().frame(width: 90)
                        }
                        .accessibilityLabel(String(localized: "放上台：\(model.filmName(for: photo.recipe.filmID))"))
                }
                Button { adding = true } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 58)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "多选添加"))
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 62)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func action(_ title: String, _ symbol: String, lit: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { actionLabel(title, symbol, lit: lit) }.buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, _ symbol: String?, lit: Bool = false) -> some View {
        VStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 17, weight: .medium)) }
            else { Text(title).font(.system(size: 15, weight: .bold)) }
            Text(symbol == nil ? String(localized: "纸张") : title).font(.system(size: 10, weight: .medium))
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(lit ? Color.labRed.opacity(0.35) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var status: String {
        guard let t = table else { return "" }
        if let undo { return undo.text }
        if loupeMode { return String(localized: "放大镜 · \(Int(loupeMag))× · 手指按哪里看哪里，按住不动凑近") }
        if trayOpen && t.selected == nil { return String(localized: "点一下放到中间，或者拖到台上") }
        if !lampOn { return String(localized: "灯关着") }
        let n = t.model.order.count
        if let id = t.selected, let it = t.model.item(id) {
            let l = it.lying
            return "\(t.caption(id)) · \(LightTable.mm(l.width)) × \(LightTable.mm(l.height)) mm"
        }
        let paper = t.model.paper.name + (t.model.portrait ? "" : String(localized: " · 横向"))
        if n == 0 { return paper }
        if t.viewport.isZoomed { return String(localized: "\(n) 张 · \(String(format: "%.1f", t.viewport.zoom))×") }
        return String(localized: "\(n) 张 · \(paper)")
    }

    // MARK: what the controls do

    /// The chosen backlight, no brighter than this screen can go past white.
    /// The lamp's level now: off is an unlit diffuser.
    private var lampGlow: Double { lampOn ? (edr ? Self.glow(glow) : 1) : 0.16 }

    private func applyGlow() { table?.glow = lampGlow }

    private func toggleLamp() {
        lampOn.toggle()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let target = lampGlow
        // On, the tube strikes past where it settles: a third over, and at least a little past SDR white.
        table?.setLamp(on: lampOn, glow: target,
                       peak: min(max(target * 1.35, 1.6), max(Double(UIScreen.main.potentialEDRHeadroom), 1)))
    }

    private static func glow(_ level: Double) -> Double { max(1, min(level, Double(UIScreen.main.potentialEDRHeadroom))) }

    private func arrange(_ text: String, _ run: (LightTableController) -> Void) {
        guard let table, count > 0 else { return }
        let kept = table.snapshot(), n = count
        if loupeMode { toggleLoupe() }
        run(table)
        offerUndo(kept, String(localized: "\(text) · \(n) 张"))
    }

    private func setTable(paper: LightTablePaper? = nil, portrait: Bool? = nil) {
        guard let table else { return }
        let kept = table.snapshot()
        if loupeMode { toggleLoupe() }
        guard table.setTable(paper: paper ?? table.model.paper, portrait: portrait ?? table.model.portrait) else { return }
        if count > 0 { offerUndo(kept, table.model.paper.name + (table.model.portrait ? String(localized: " · 竖向") : String(localized: " · 横向"))) }
    }

    /// Films back to their size before a pinch: these, or all.
    /// The whole table as one picture (4096 px on its long side, Display P3 JPEG), handed to the share sheet: save it
    /// to Photos, AirDrop it, send it. Upstream's Poster / Contact Sheet export, as one plain picture.
    private func exportTable() {
        guard let table, let image = table.exportPicture(longEdge: 4096) else { return }
        let stamp = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Spektra Cam \(String(localized: "观片台")) \(stamp).jpg")
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        ShareController.present(url: url) { try? FileManager.default.removeItem(at: url) }
    }

    private func resetSizes(_ ids: [UUID]? = nil) {
        model.resetLightTableScales(ids)
        table?.sync(model.lightTableFrames)
    }

    private func toggleLoupe() {
        guard let table else { return }
        loupeMode.toggle()
        if loupeMode {
            table.select(nil)
            table.loupe(at: CGPoint(x: table.viewport.size.width / 2, y: table.viewport.size.height / 2))
        } else {
            table.loupe(at: nil)
        }
    }

    private func offerUndo(_ kept: LightTableModel, _ text: String) {
        let next = Undo(kept: kept, text: text)
        withAnimation(motion) { undo = next }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if undo?.token == next.token { withAnimation(motion) { undo = nil } }
        }
    }

    private func undoNow() {
        guard let table, let undo else { return }
        table.restore(undo.kept)
        withAnimation(motion) { self.undo = nil }
    }

    private func layDown(_ ids: [UUID]) {
        guard let table else { return }
        undo = nil
        table.add(ids.filter { !table.model.order.contains($0) })
        table.select(nil)
    }
}

/// 添加: the library's photos, newest first, picked by a tap; 放上 n 张.
struct LightTableAddSheet: View {
    @ObservedObject var model: ViewModel
    let onTable: Set<UUID>
    let room: Int
    let layDown: ([UUID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [UUID] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(model.library) { photo in
                        let on = onTable.contains(photo.id), k = picked.firstIndex(of: photo.id)
                        Color.labPanel
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { Image(uiImage: photo.thumbnail).resizable().scaledToFill() }
                            .overlay { if on { Color.black.opacity(0.55) } }
                            .overlay(alignment: .topTrailing) {
                                if let k {
                                    Text("\(k + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 22, height: 22).background(Color.labRed, in: Circle()).padding(5)
                                } else if on {
                                    Text(String(localized: "已在台上")).font(.system(size: 9, weight: .semibold)).padding(5)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !on else { return }
                                if let k { picked.remove(at: k) } else if picked.count < room { picked.append(photo.id) }
                            }
                            .accessibilityLabel(model.filmName(for: photo.recipe.filmID))
                            .accessibilityAddTraits(k != nil ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle(picked.isEmpty ? String(localized: "添加到观片台") : String(localized: "已选 \(picked.count) 张"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "放上 \(picked.count) 张")) { layDown(picked); dismiss() }.disabled(picked.isEmpty)
                }
            }
            .background(Color.labInk.ignoresSafeArea())
        }
        .tint(Color.labRed)
        .preferredColorScheme(.dark)
    }
}

/// A long press beside the table's own gestures: it begins only when the finger stays put (a drag that starts
/// first carries the film instead). Once it has begun the table's other gestures are switched off until the finger
/// lifts, and the press reports where the finger is (nil when it lifts).
final class LongPressOpen: NSObject, UIGestureRecognizerDelegate {
    private let track: (CGPoint?) -> Void
    /// Whether a press may begin at all (the loupe tool on): off, it never begins, so it cancels no carry.
    private let enabled: () -> Bool
    private static var kept: [LongPressOpen] = []

    private init(_ track: @escaping (CGPoint?) -> Void, enabled: @escaping () -> Bool) { self.track = track; self.enabled = enabled }

    @MainActor static func attach(to view: UIView, enabled: @escaping () -> Bool = { true }, track: @escaping (CGPoint?) -> Void) {
        let target = LongPressOpen(track, enabled: enabled)
        kept.append(target)
        let press = UILongPressGestureRecognizer(target: target, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.45
        press.allowableMovement = 8
        press.cancelsTouchesInView = false
        press.delegate = target
        view.addGestureRecognizer(press)
    }

    @MainActor @objc private func pressed(_ r: UILongPressGestureRecognizer) {
        guard let v = r.view else { return }
        let others = (v.gestureRecognizers ?? []).filter { $0 !== r }
        switch r.state {
        case .began:
            others.forEach { $0.isEnabled = false; $0.isEnabled = true }      // cancels a carry or a hold in progress
            track(r.location(in: v))
        case .changed:
            track(r.location(in: v))
        default:
            track(nil)
        }
    }

    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { MainActor.assumeIsolated { enabled() } }
}


/// A light-table loupe seen from above, as the eye sees one standing on the film: the clear foot's rim round exactly
/// what the lens shows (`radius`, the 3× view's own footprint), a dark eyepiece ring over it with clear glass in
/// it, and a soft shadow — rings only, so the film under it stays in view.
struct LoupeModel: View {
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = radius
            func ring(_ rr: CGFloat) -> CGRect { CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2) }
            // Its shadow on the table, a little down and right of the foot (the light from above left).
            var shadow = ctx
            shadow.addFilter(.blur(radius: 5))
            shadow.stroke(Path(ellipseIn: ring(r + 2).offsetBy(dx: 3, dy: 4)), with: .color(.black.opacity(0.45)), lineWidth: 5)
            // The clear acrylic wall, seen from above as a band between the foot and the eyepiece: brighter where it
            // faces the light.
            let wall = Path(ellipseIn: ring(r)).subtracting(Path(ellipseIn: ring(r - 7)))
            ctx.fill(wall, with: .linearGradient(Gradient(colors: [.white.opacity(0.34), .white.opacity(0.06)]),
                                                 startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)))
            ctx.stroke(Path(ellipseIn: ring(r)), with: .color(.white.opacity(0.7)), lineWidth: 1.2)
            ctx.stroke(Path(ellipseIn: ring(r - 7)), with: .color(.white.opacity(0.25)), lineWidth: 0.8)
            // The eyepiece rim: a thin dark knurled ring just inside the wall.
            let eye = Path(ellipseIn: ring(r - 7)).subtracting(Path(ellipseIn: ring(r - 11)))
            ctx.fill(eye, with: .color(Color(white: 0.08).opacity(0.85)))
            for i in 0..<48 {
                let a = CGFloat(i) / 48 * 2 * .pi
                var tick = Path()
                tick.move(to: CGPoint(x: c.x + (r - 10.5) * cos(a), y: c.y + (r - 10.5) * sin(a)))
                tick.addLine(to: CGPoint(x: c.x + (r - 7.5) * cos(a), y: c.y + (r - 7.5) * sin(a)))
                ctx.stroke(tick, with: .color(.white.opacity(0.14)), lineWidth: 0.7)
            }
            // The glass: clear, a faint cool tint and one reflection at the top left.
            ctx.fill(Path(ellipseIn: ring(r - 11)), with: .color(Color(red: 0.6, green: 0.75, blue: 0.9).opacity(0.06)))
            var glint = Path()
            glint.addArc(center: c, radius: r - 15, startAngle: .degrees(200), endAngle: .degrees(240), clockwise: false)
            ctx.stroke(glint, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}
