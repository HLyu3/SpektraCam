//  LightTablePane.swift — 观片台: this app's page round upstream's light table (`LightTableController`,
//  `LightTableView`, `LightTableGestures`, all upstream's). Written for this app, after upstream's
//  `LightTablePane` (whose page is the Mac's now): top bar ‹ 观片台 ···, the table, a status line with
//  Undo for 6 s, and a row of actions — at rest 添加 · 放大镜 · 适合 · 纸张 · 方向; with a film chosen
//  转 90° · 拉近 · 拿走.

import SwiftUI

extension ViewModel {
    /// Every photo of the library as the light table reads it.
    var lightTableFrames: [LibraryFrame] {
        let print = UserDefaults.standard.object(forKey: Self.lightTablePrintKey) as? Bool ?? true
        let scales = UserDefaults.standard.dictionary(forKey: Self.lightTableScalesKey) as? [String: Double] ?? [:]
        return library.map { p in
            let url = thumbnailURL(for: p.id)
            let base = LightTableFrames.sizeMM(of: p, print: print)
            let k = scales[p.id.uuidString] ?? 1
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return LibraryFrame(id: p.id, sizeMM: CGSize(width: base.width * k, height: base.height * k), thumbnail: url,
                                large: largeDevelopURL(for: p.id), stamp: stamp,
                                caption: filmName(for: p.recipe.filmStock))
        }
    }

    var lightTableStoreURL: URL { libraryRootURL.appendingPathComponent(LightTableStore.fileName) }

    /// Films lie at print size (true) or as the negative (false).
    static let lightTablePrintKey = "SpektraLab.lightTablePrint"
    /// Each film's own scale from a pinch, by photo id.
    static let lightTableScalesKey = "SpektraLab.lightTableScales"

    /// A pinch ended: the film's scale against its base size, kept for next time.
    func setLightTableSize(_ id: UUID, _ size: CGSize) {
        guard let p = library.first(where: { $0.id == id }) else { return }
        let print = UserDefaults.standard.object(forKey: Self.lightTablePrintKey) as? Bool ?? true
        let base = LightTableFrames.sizeMM(of: p, print: print)
        var scales = UserDefaults.standard.dictionary(forKey: Self.lightTableScalesKey) as? [String: Double] ?? [:]
        scales[id.uuidString] = Double(size.width / max(base.width, 0.01))
        UserDefaults.standard.set(scales, forKey: Self.lightTableScalesKey)
    }

    /// The 2048 px develop kept beside the thumbnail for the light table and the slide show.
    func largeDevelopURL(for id: UUID) -> URL { libraryRootURL.appendingPathComponent("\(id.uuidString)-large.jpg") }

    /// That develop, made now if missing or older than the thumbnail. Nil while the engine is busy elsewhere.
    func largeDevelop(for id: UUID) async -> UIImage? {
        let url = largeDevelopURL(for: id)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let thumb = (try? thumbnailURL(for: id).resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
        if let made = (try? url.resourceValues(forKeys: keys))?.contentModificationDate, made >= thumb,
           let image = UIImage(contentsOfFile: url.path) { return image }
        guard let image = await slideImage(for: id) else { return nil }
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
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where !queue.contains(id) { queue.append(id) }
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let id = queue.removeFirst()
        table?.setMaking([id: -1])
        Task { @MainActor in
            let made = await model.largeDevelop(for: id) != nil
            running = false
            table?.setMaking([:])
            if made { table?.rendersChanged() } else { queue.removeAll() }      // engine busy: asked again later
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var table: LightTableController?
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
    /// Films at print size (a 5-inch print) or as the negative.
    @AppStorage(ViewModel.lightTablePrintKey) private var printSize = true

    private struct Undo: Equatable {
        var kept: LightTableModel
        var text: String
        var token = UUID()
    }

    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
    private var count: Int { table?.model.order.count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            tableArea
            band
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: open)
        .onDisappear { table?.close() }
        .onChange(of: glow) { _, _ in applyGlow() }
        .onChange(of: printSize) { _, _ in table?.sync(model.lightTableFrames) }
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
        if let table { table.reopen(model.lightTableFrames); return }
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
        LightTable.mag = loupeMag
        table = c
        if !laying.isEmpty {
            // A moment after, so the view has its size and the free spots are its.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                layDown(laying)
            }
        }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack {
            if embedded {
                Text("观片台").font(.system(size: 28, weight: .bold)).padding(.leading, 8)
                Spacer()
            } else {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("返回")
                Spacer()
                Text("观片台").font(.headline)
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
            .accessibilityLabel("幻灯")
            Menu {
                Toggle(isOn: $edr) { Label("EDR 背光", systemImage: "sun.max") }
                Picker("背光亮度", selection: $glow) {
                    Text("背光 · 标准").tag(1.0)
                    Text("背光 · 明亮").tag(2.0)
                    Text("背光 · 最亮").tag(4.0)
                }
                .disabled(!edr)
                Divider()
                Picker("照片尺寸", selection: $printSize) {
                    Text("照片 · 相片尺寸").tag(true)
                    Text("照片 · 底片实际尺寸").tag(false)
                }
                Button {
                    UserDefaults.standard.removeObject(forKey: ViewModel.lightTableScalesKey)
                    table?.sync(model.lightTableFrames)
                } label: { Label("照片恢复原大小", systemImage: "arrow.uturn.backward") }
                Divider()
                Button { table?.fit() } label: { Label("适合屏幕", systemImage: "arrow.down.right.and.arrow.up.left") }
                Picker("纸张", selection: Binding(get: { table?.model.paper ?? .a4 }, set: { setTable(paper: $0) })) {
                    ForEach(LightTablePaper.allCases) { paper in
                        Text("灯箱 · \(paper.name)（\(Int(paper.size.width))×\(Int(paper.size.height)) mm）").tag(paper)
                    }
                }
                Button { setTable(portrait: !(table?.model.portrait ?? true)) } label: {
                    Label((table?.model.portrait ?? true) ? "灯箱转成横向" : "灯箱转成竖向", systemImage: "rectangle.portrait.rotate")
                }
                Divider()
                Group {
                Button { arrange("排整齐") { $0.tidyUp($0.model.order) } } label: { Label("排整齐", systemImage: "square.grid.3x3") }
                Button { arrange("随机摆放") { $0.random() } } label: { Label("随机摆放", systemImage: "shuffle") }
                Button { arrange("打乱") { $0.scatter() } } label: { Label("打乱", systemImage: "rectangle.on.rectangle.angled") }
                Divider()
                Button(role: .destructive) { arrange("全部拿走") { $0.removeAll() } } label: { Label("全部拿走", systemImage: "trash") }
                }
                .disabled(count == 0)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("更多")
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
                    // This app: a long press anywhere on the table is the immersive loupe (upstream has no long press).
                    LongPressOpen.attach(to: view) { p in
                        if let p {
                            if !LightTable.bigLens { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                            table.immersiveLoupe(at: p)
                        } else {
                            table.immersiveLoupe(at: nil)
                            // Back to the loupe tool's lens if it was on.
                            if loupeMode { table.loupe(at: CGPoint(x: table.viewport.size.width / 2, y: table.viewport.size.height / 2)) }
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
                        Label("从图库添加", systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 20).frame(height: 46)
                            .labGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.labCream)
                    .frame(maxHeight: .infinity)
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
        } else {
            Color.clear
        }
    }

    // MARK: the band

    private var band: some View {
        VStack(spacing: 10) {
            if trayOpen && table?.selected == nil { tray }
            HStack(spacing: 8) {
                Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if undo != nil {
                    Button("撤销") { undoNow() }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
            }
            .frame(height: 28)
            HStack(spacing: 10) {
                if let table, let id = table.selected {
                    action("转 90°", "rotate.left") { table.turnQuarter(id) }
                    action("拉近", "plus.magnifyingglass") { table.zoomToFilm(id) }
                    action("拿走", "tray.and.arrow.up") {
                        let kept = table.snapshot(), name = table.caption(id)
                        table.remove(id)
                        offerUndo(kept, "拿走了 · " + name)
                    }
                    action("完成", "checkmark") { table.select(nil) }
                } else {
                    action("胶片托盘", "tray", lit: trayOpen) {
                        if loupeMode { toggleLoupe() }
                        withAnimation(.snappy(duration: 0.25)) { trayOpen.toggle() }
                    }
                    action(lampOn ? "关灯" : "开灯", lampOn ? "lightbulb.fill" : "lightbulb.slash", lit: !lampOn) { toggleLamp() }
                    action("放大镜", "magnifyingglass", lit: loupeMode) { toggleLoupe() }
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
            HStack(spacing: 6) {
                if waiting.isEmpty {
                    Text("图库里的照片都在台上了").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
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
                        .accessibilityLabel("放上台：\(model.filmName(for: photo.recipe.filmStock))")
                }
                Button { adding = true } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 58)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("多选添加")
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
            Text(symbol == nil ? "纸张" : title).font(.system(size: 10, weight: .medium))
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(lit ? Color.labRed.opacity(0.35) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var status: String {
        guard let t = table else { return "" }
        if let undo { return undo.text }
        if loupeMode { return "放大镜 · \(Int(loupeMag))× · 手指按哪里看哪里，按住不动凑近" }
        if trayOpen && t.selected == nil { return "点一下放到中间，或者拖到台上" }
        if !lampOn { return "灯关着" }
        let n = t.model.order.count
        if let id = t.selected, let it = t.model.item(id) {
            let l = it.lying
            return "\(t.caption(id)) · \(LightTable.mm(l.width)) × \(LightTable.mm(l.height)) mm"
        }
        let paper = t.model.paper.name + (t.model.portrait ? "" : " · 横向")
        if n == 0 { return paper }
        if t.viewport.isZoomed { return "\(n) 张 · \(String(format: "%.1f", t.viewport.zoom))×" }
        return "\(n) 张 · \(paper)"
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
        offerUndo(kept, "\(text) · \(n) 张")
    }

    private func setTable(paper: LightTablePaper? = nil, portrait: Bool? = nil) {
        guard let table else { return }
        let kept = table.snapshot()
        if loupeMode { toggleLoupe() }
        guard table.setTable(paper: paper ?? table.model.paper, portrait: portrait ?? table.model.portrait) else { return }
        if count > 0 { offerUndo(kept, table.model.paper.name + (table.model.portrait ? " · 竖向" : " · 横向")) }
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
                                    Text("已在台上").font(.system(size: 9, weight: .semibold)).padding(5)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !on else { return }
                                if let k { picked.remove(at: k) } else if picked.count < room { picked.append(photo.id) }
                            }
                            .accessibilityLabel(model.filmName(for: photo.recipe.filmStock))
                            .accessibilityAddTraits(k != nil ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle(picked.isEmpty ? "添加到观片台" : "已选 \(picked.count) 张")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("放上 \(picked.count) 张") { layDown(picked); dismiss() }.disabled(picked.isEmpty)
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
    private static var kept: [LongPressOpen] = []

    private init(_ track: @escaping (CGPoint?) -> Void) { self.track = track }

    @MainActor static func attach(to view: UIView, track: @escaping (CGPoint?) -> Void) {
        let target = LongPressOpen(track)
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
}
