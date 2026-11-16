//  LightTablePane.swift — 观片台: this app's page round upstream's light table (`LightTableController`,
//  `LightTableView`, `LightTableGestures`, all upstream's). Written for this app, after upstream's
//  `LightTablePane` (whose page is the Mac's now): top bar ‹ 观片台 ···, the table, a status line with
//  Undo for 6 s, and a row of actions — at rest 添加 · 放大镜 · 适合 · 纸张 · 方向; with a film chosen
//  转 90° · 拉近 · 拿走.

import SwiftUI

extension ViewModel {
    /// Every photo of the library as the light table reads it.
    var lightTableFrames: [LibraryFrame] {
        library.map { p in
            let url = thumbnailURL(for: p.id)
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return LibraryFrame(id: p.id, sizeMM: LightTableFrames.sizeMM(of: p), thumbnail: url, stamp: stamp,
                                caption: filmName(for: p.recipe.filmStock))
        }
    }

    var lightTableStoreURL: URL { libraryRootURL.appendingPathComponent(LightTableStore.fileName) }
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
        .onChange(of: edr) { _, _ in applyGlow() }
        .onChange(of: loupeMag) { _, m in
            LightTable.mag = m
            if loupeMode, let t = table { t.loupe(at: t.loupeCentre) }      // redrawn at the new power
        }
        .onChange(of: model.library.map(\.id)) { _, _ in table?.sync(model.lightTableFrames) }
        .fullScreenCover(isPresented: $showing) {
            LightTableSlideShow(model: model, ids: table?.model.order ?? [])
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
            Button { toggleLamp() } label: {
                Image(systemName: lampOn ? "lightbulb.fill" : "lightbulb.slash")
                    .font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 44)
                    .foregroundStyle(lampOn ? Color.labCream : Color.labCream.opacity(0.5))
            }
            .accessibilityLabel(lampOn ? "关灯" : "开灯")
            Button { showing = true } label: {
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
                Picker("放大镜倍率", selection: $loupeMag) {
                    ForEach([2.0, 3.0, 5.0, 8.0], id: \.self) { Text("放大镜 · \(Int($0))×").tag($0) }
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
                    view.describe = { id in (table.caption(id), "") }
                    view.activate = { id in
                        if table.selected == id { table.select(nil) } else { table.select(id); table.bringToTop(id) }
                    }
                    view.escape = { table.select(nil) }
                }
                .clipped()
                if table.model.order.isEmpty {
                    Button { adding = true } label: {
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
            if loupeMode {
                Picker("倍率", selection: $loupeMag) {
                    ForEach([2.0, 3.0, 5.0, 8.0], id: \.self) { Text("\(Int($0))×").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
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
                    action("添加", "plus") {
                        if loupeMode { toggleLoupe() }
                        adding = true
                    }
                    .disabled(count >= LightTable.films)
                    action("放大镜", "magnifyingglass", lit: loupeMode) { toggleLoupe() }
                    action("适合", "arrow.down.right.and.arrow.up.left") { table?.fit() }
                    Menu {
                        ForEach(LightTablePaper.allCases) { paper in
                            Button {
                                setTable(paper: paper)
                            } label: {
                                let s = paper.size
                                if table?.model.paper == paper {
                                    Label("\(paper.name) · \(Int(s.width))×\(Int(s.height)) mm", systemImage: "checkmark")
                                } else {
                                    Text("\(paper.name) · \(Int(s.width))×\(Int(s.height)) mm")
                                }
                            }
                        }
                    } label: {
                        actionLabel(table?.model.paper.name ?? "A4", nil)
                    }
                    action("方向", (table?.model.portrait ?? true) ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                        setTable(portrait: !(table?.model.portrait ?? true))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .foregroundStyle(Color.labCream)
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
