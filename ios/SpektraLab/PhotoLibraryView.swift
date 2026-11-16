//  PhotoLibraryView.swift — the wall the app opens to.
//
//  The editor is a place you visit, not the app's front door. Importing fills
//  this wall; tapping a print opens it in the editor; going back saves the look
//  and refreshes its thumbnail. Recipes are copied from one print and pasted
//  onto a multi-selection, like a contact sheet with one grade.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.editingPhotoID != nil && !model.batchExporting {
                EditorView()
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
            } else {
                MainTabs()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.editingPhotoID)
        .preferredColorScheme(.dark)
        // A photo or RAW sent from another app ("Open in" / "Copy to SpektraLab"): imported like a file; its Inbox copy
        // goes once it is in the library.
        .onOpenURL { url in
            Task { @MainActor in
                await model.importFiles(from: [url])
                if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.sceneBecameActive() }
            if phase == .background { model.sceneWentToBackground() }
        }
#if DEBUG
        .task {
            let environment = ProcessInfo.processInfo.environment
            // UI tests only. Without this guard every Debug launch opened the wall's first photo.
            guard environment.keys.contains(where: { $0.hasPrefix("SPEKTRAFILM_UI_TEST") }) else { return }
            let libraryPaths = (environment["SPEKTRAFILM_UI_TEST_LIBRARY_PATHS"] ?? "")
                .split(separator: "|")
                .map { URL(fileURLWithPath: String($0)) }
            if !libraryPaths.isEmpty {
                await model.importFiles(from: libraryPaths)
            } else if let path = environment["SPEKTRAFILM_UI_TEST_PATH"], !path.isEmpty,
                      model.library.isEmpty {
                await model.importFile(from: URL(fileURLWithPath: path))
            }
            if environment["SPEKTRAFILM_UI_TEST_IMPORT_ONLY"] != "1",
               let first = model.library.first {
                await model.openLibraryPhoto(first.id)
            }
            if let value = environment["SPEKTRAFILM_UI_TEST_CLOSE_AFTER"],
               let seconds = Double(value) {
                try? await Task.sleep(for: .seconds(seconds))
                model.closeEditor()
                try? await Task.sleep(for: .seconds(2))
            }
            if environment["SPEKTRAFILM_UI_TEST_COPY_FIRST"] == "1",
               let first = model.library.first {
                model.copyRecipe(from: first.id)
                try? await Task.sleep(for: .seconds(1))
            }
            if environment["SPEKTRAFILM_UI_TEST_PASTE_ALL"] == "1" {
                await model.pasteRecipe(to: Set(model.library.map(\.id)))
            }
        }
#endif
    }
}

struct PhotoLibraryView: View {
    @EnvironmentObject private var model: ViewModel
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    /// Long-press-and-slide selection: each tile's frame in the wall, and the slide under way.
    @State private var tileFrames: [UUID: CGRect] = [:]
    @State private var slide: SlideRun?
    private struct SlideRun { var order: [UUID]; var anchor: Int; var adding: Bool; var base: Set<UUID> }
    @State private var pairing: PairSpec?
    @State private var showingPicker = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var culling = false
    /// Tiles a row: 2…5, pinched on the wall.
    @AppStorage("SpektraLab.libraryColumns") private var columnCount = 3
    /// The zoom levels a pinch steps through, as Photos does: tiles a row.
    private static let levels = [1, 2, 3, 4, 5, 7, 10, 14]
    /// The level a pinch started from.
    @State private var pinchStart: Int?
    /// Dense levels: no labels, a section a month.
    private var dense: Bool { columnCount >= 7 }
    /// "all", "imported", "captured", "favorite", "raw", "edited", "pair", or "film:<id>".
    @AppStorage("SpektraLab.libraryFilter") private var filter = "all"
    /// The wall's order: "shot" (when taken), "added" (when it joined the library), "film" (by film name).
    @AppStorage("SpektraLab.librarySort") private var sort = "added"
    @AppStorage("SpektraLab.librarySortOldestFirst") private var oldestFirst = false
    /// "app": the wall is SpektraLab's own; "photos": the system library, read in place, is a view too.
    @AppStorage("SpektraLab.librarySource") private var source = "app"
    private var showingSystemPhotos: Bool { source == "photos" && filter == "photos" }
    @StateObject private var photosFeed = PhotosFeed()
    /// System photos picked in the 系统相册 view, in the order tapped (a pair reads left to right).
    @State private var selectedAssets: [String] = []
    @State private var deleteIDs: Set<UUID> = []
    @State private var showingDelete = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: dense ? 1 : 3, alignment: .top), count: min(max(columnCount, 1), 14))
    }

    private var selectablePhotoIDs: Set<UUID> {
        var ids = Set(visiblePhotos.map(\.id))
        if let source = model.recipeSourcePhotoID {
            ids.remove(source)
        }
        return ids
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LabBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if selecting, let recipe = model.clipboardRecipe {
                        clipboardBanner(recipe)
                    }
                    if !selecting, let r = model.cullReminder {
                        cullBanner(r)
                    }
                    if showingSystemPhotos {
                        sectionHeader
                        PhotosWall(model: model, feed: photosFeed, selecting: selecting, selected: $selectedAssets,
                                   columnCount: min(max(columnCount, 1), 14))
                    } else if model.library.isEmpty {
                        // The chips stay while 系统相册 is on: without them an empty 全部 had no way back.
                        if source == "photos" { sectionHeader }
                        emptyState
                    } else {
                        sectionHeader
                        wall
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, selecting ? 148 : 24)
            }
            .scrollIndicators(.hidden)
            // Photos scrolling under the status bar fade out instead of showing through it.
            .overlay(alignment: .top) {
                GeometryReader { g in
                    LinearGradient(colors: [Color.labInk, Color.labInk.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: g.safeAreaInsets.top + 18)
                        .offset(y: -g.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
            }
            // Pinch the wall for more or fewer tiles a row.
            // Pinch as in Photos: the wall steps through its levels while the fingers move (spread = bigger tiles).
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let levels = Self.levels
                    let start = pinchStart ?? (levels.firstIndex(of: columnCount) ?? levels.firstIndex { $0 >= columnCount } ?? 2)
                    pinchStart = start
                    let steps = Int((-log(v.magnification) / log(1.4)).rounded())
                    let next = levels[min(max(start + steps, 0), levels.count - 1)]
                    if next != columnCount { withAnimation(.snappy(duration: 0.22)) { columnCount = next } }
                }
                .onEnded { _ in pinchStart = nil })

            if selecting {
                Group { if showingSystemPhotos { photosSelectionBar } else { selectionBar } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }

            if let message = model.libraryMessage {
                toast(message)
                    .padding(.horizontal, 20)
                    .padding(.bottom, selecting ? 128 : 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
            }

            if let busy = model.libraryBusy {
                busyOverlay(busy)
                    .transition(.opacity)
                    .zIndex(4)
            }
        }
        .animation(.snappy(duration: 0.28), value: selecting)
        .animation(.snappy(duration: 0.22), value: selected)
        .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
        .fullScreenCover(isPresented: $culling) { CullView(model: model) }
        .task(id: model.library.count) { await model.fillCaptureDates() }
        .onAppear { model.pruneDeletedAssets() }
        .onChange(of: scenePhase) { _, phase in
            // Back from Photos, where a photo may have been deleted.
            if phase == .active { model.pruneDeletedAssets() }
        }
        .sheet(item: $pairing) { spec in
            PairSheet(model: model, spec: spec) { selected.removeAll() }
        }
        .animation(.snappy(duration: 0.22), value: model.libraryMessage)
        .animation(.easeInOut(duration: 0.18), value: model.libraryBusy)
        .sensoryFeedback(.selection, trigger: selected)
        .onChange(of: model.recipeSourcePhotoID) { _, source in
            if let source {
                selected.remove(source)
            }
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.image, .rawImage, .folder],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { @MainActor in await model.importFiles(from: urls) }
        }
        .alert(model.importFailures.map { "\($0.lines.count) 张没能导入" } ?? "",
               isPresented: Binding(get: { model.importFailures != nil }, set: { if !$0 { model.importFailures = nil } }),
               presenting: model.importFailures) { _ in
            Button("好") {}
        } message: { f in
            Text(f.summary + "\n\n" + f.lines.joined(separator: "\n"))
        }
        .confirmationDialog("这 \(model.reimportOffer?.count ?? 0) 张都导入过了",
                            isPresented: Binding(get: { model.reimportOffer != nil }, set: { if !$0 { model.reimportOffer = nil } }),
                            titleVisibility: .visible, presenting: model.reimportOffer) { offer in
            Button("再导入一次") { Task { @MainActor in await model.importFiles(from: offer.urls, again: true) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("会作为新照片再加进底片，已有的不受影响。")
        }
        .confirmationDialog("删除这些照片？",
                            isPresented: $showingDelete,
                            titleVisibility: .visible) {
            Button("删除 \(deleteIDs.count) 张照片", role: .destructive) {
                model.deletePhotos(deleteIDs)
                selected.subtract(deleteIDs)
                deleteIDs = []
                if model.library.isEmpty { selecting = false }
            }
            Button("取消", role: .cancel) { deleteIDs = [] }
        } message: {
            Text("原图和缩略图都会从 Spektra Cam 的照片库移除，不会影响系统相册。")
        }
        .task(id: model.libraryMessage) {
            guard model.libraryMessage != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            model.clearLibraryMessage()
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SPEKTRA CAM · 暗房")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.labRed.opacity(0.9))
                Text(selecting ? "选择照片" : "底片")
                    .font(.system(size: 36, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Color.labCream)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.labCream.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if !model.library.isEmpty {
                        headerButton(selecting ? "xmark" : "checkmark.circle", selecting ? "结束选择" : "选择照片") {
                            withAnimation(.snappy(duration: 0.2)) {
                                selecting.toggle()
                                if !selecting { selected.removeAll(); selectedAssets.removeAll() }
                            }
                        }
                    }
                    if !selecting {
                        Menu {
                            Button { showingPicker = true } label: { Label("从“照片”选…", systemImage: "photo.on.rectangle") }
                            Button { showingFileImporter = true } label: { Label("从文件 / 存储卡导入…", systemImage: "sdcard") }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.labCream)
                                .frame(width: 44, height: 44)
                                .labGlassInteractive(in: Circle())
                        }
                        .accessibilityLabel("导入照片")
                        headerButton("gearshape", "设置") { showingSettings = true }
                    }
                }
            }
        }
        .padding(.top, 2)
        .photosPicker(isPresented: $showingPicker, selection: $pickerItems, maxSelectionCount: 100,
                      matching: .images, photoLibrary: .shared())
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { @MainActor in
                await model.importPickedItems(items)
                pickerItems = []
            }
        }
    }

    private func headerButton(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.labCream)
                .frame(width: 44, height: 44)
                .labGlassInteractive(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var subtitle: String {
        let edited = model.library.filter(\.isEdited).count
        if model.library.isEmpty { return "导入一组照片，统一调色" }
        if selecting {
            return selected.isEmpty ? "轻点照片进行多选" : "已选 \(selected.count) 张 · 共 \(model.library.count) 张"
        }
        let today = model.library.filter { $0.captured && Calendar.current.isDateInToday($0.createdAt) }.count
        return "\(model.library.count) 张" + (today > 0 ? " · 今天拍了 \(today) 张" : "") + " · \(edited) 张已调色"
    }

    /// Shots from the camera that have waited days without an export.
    private func cullBanner(_ r: (count: Int, bytes: Int64, soon: Int)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "camera")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.labCream.opacity(0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%d 张拍了 %d 天以上还没导出 · %.1f GB", r.count, ViewModel.cullReminderDays,
                            Double(r.bytes) / 1_073_741_824))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.labCream)
                if r.soon > 0 {
                    Text("其中 \(r.soon) 张将在 1 天内自动删除")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.labRed)
                }
            }
            Spacer(minLength: 4)
            Button("稍后") { model.snoozeCullReminder() }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.labCream.opacity(0.5))
            Button { culling = true } label: {
                Text("去挑片")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.labCream, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .labGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func clipboardBanner(_ recipe: PhotoRecipe) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.labCream.opacity(0.58))
            Text("剪贴板配方")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.labCream.opacity(0.48))
            Text(model.filmName(for: recipe.filmID))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.labCream.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Text(model.recipeSourcePhotoID != nil
                 ? "来源照片已锁定"
                 : (selecting ? "选择后粘贴" : "长按照片可复制"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.labCream.opacity(0.38))
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .labGlass(in: Capsule())
    }

    private var sectionHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            if selecting {
                Text("轻点选择 · 横向滑动连选")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.labCream.opacity(0.76))
                Spacer()
                Text(showingSystemPhotos ? "\(selectedAssets.count)" : "\(selected.count) / \(visiblePhotos.count)")
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.labCream.opacity(0.34))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if source == "photos" { chip("系统相册", "photos", symbol: "photo.on.rectangle") }
                        chip("全部 \(model.library.count)", "all")
                        chip("拍摄", "captured", symbol: "camera")
                        chip("导入", "imported")
                        chip("收藏", "favorite", symbol: "heart")
                        chip("已调色", "edited")
                        chip("RAW", "raw")
                        if count("pair") > 0 { chip("双拼", "pair") }
                        filmChip
                    }
                    .padding(.horizontal, 1)
                }
                // Clipped, with a soft edge: the chips used to run on under the sort button.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                if showingSystemPhotos { PhotoAlbumMenu(feed: photosFeed) } else { cullButton; sortMenu.fixedSize() }
            }
        }
    }

    /// 挑片, always in reach beside the sort (it was the last chip of the row, off screen); the count of
    /// never-exported shots on it.
    private var cullButton: some View {
        let unexported = model.unexportedShots().count
        return Button { culling = true } label: {
            Image(systemName: "checkmark.rectangle.stack")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(unexported > 0 ? Color.labRed : Color.labCream.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(unexported > 0 ? 0.12 : 0.06), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if unexported > 0 {
                        Text("\(unexported)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(Color.labRed, in: Capsule())
                            .offset(x: 6, y: -5)
                    }
                }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(unexported > 0 ? "挑片，\(unexported) 张没导出" : "挑片")
    }

    /// One filter, a tap away; the chosen one lit in amber.
    private func chip(_ title: String, _ value: String, symbol: String? = nil) -> some View {
        let on = filter == value
        return Button {
            withAnimation(.snappy(duration: 0.2)) { filter = value }
        } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .foregroundStyle(on ? Color.black : Color.labCream.opacity(0.8))
            .background(on ? AnyShapeStyle(Color.labRed) : AnyShapeStyle(Color.white.opacity(0.07)), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The films some photo is on, by how many.
    private var filmChip: some View {
        let on = filter.hasPrefix("film:")
        return Menu {
            let films = Dictionary(grouping: model.library, by: \.recipe.filmID).sorted { $0.value.count > $1.value.count }
            ForEach(films, id: \.key) { film, photos in
                Button("\(model.filmName(for: film)) · \(photos.count)") { filter = "film:" + film }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "film").font(.system(size: 10, weight: .semibold))
                Text(on ? filterTitle : "胶片")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .foregroundStyle(on ? Color.black : Color.labCream.opacity(0.8))
            .background(on ? AnyShapeStyle(Color.labRed) : AnyShapeStyle(Color.white.opacity(0.07)), in: Capsule())
        }
    }

    // MARK: - filters

    private func matches(_ p: LibraryPhoto, _ f: String) -> Bool {
        switch f {
        case "imported": return !p.captured && p.pair == nil
        case "captured": return p.captured
        case "favorite": return p.favorite
        case "raw": return p.isRAW
        case "edited": return p.isEdited
        case "pair": return p.pair != nil
        default:
            if f.hasPrefix("film:") { return p.recipe.filmID == String(f.dropFirst(5)) }
            return true
        }
    }

    private var visiblePhotos: [LibraryPhoto] {
        let shown = model.library.filter { matches($0, filter) }
        func date(_ p: LibraryPhoto) -> Date { sort == "shot" ? (p.capturedAt ?? p.createdAt) : p.createdAt }
        let newest: [LibraryPhoto]
        if sort == "film" {
            newest = shown.sorted {
                let a = model.filmName(for: $0.recipe.filmID), b = model.filmName(for: $1.recipe.filmID)
                return a == b ? $0.createdAt > $1.createdAt : a.localizedStandardCompare(b) == .orderedAscending
            }
            return oldestFirst ? Array(newest.reversed()) : newest
        }
        newest = shown.sorted { date($0) > date($1) }
        return oldestFirst ? Array(newest.reversed()) : newest
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sort) {
                Label("拍摄时间", systemImage: "camera").tag("shot")
                Label("添加时间", systemImage: "plus.square.on.square").tag("added")
                Label("胶片", systemImage: "film").tag("film")
            }
            Picker("顺序", selection: $oldestFirst) {
                Text(sort == "film" ? "A → Z" : "新的在前").tag(false)
                Text(sort == "film" ? "Z → A" : "旧的在前").tag(true)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.labCream.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(sort == "added" && !oldestFirst ? 0.06 : 0.14), in: Circle())
        }
        .accessibilityLabel("排序")
    }

    private func count(_ f: String) -> Int { model.library.filter { matches($0, f) }.count }

    private var filterTitle: String {
        switch filter {
        case "imported": return "导入"
        case "captured": return "拍摄"
        case "favorite": return "收藏"
        case "raw": return "RAW"
        case "edited": return "已调色"
        case "pair": return "双拼"
        case "photos": return "系统相册"
        default:
            if filter.hasPrefix("film:") { return model.filmName(for: String(filter.dropFirst(5))) }
            return "全部照片"
        }
    }

    /// The wall in sections: a day each (by the date the sort uses), or a film each when sorted by film.
    private var sections: [(key: String, title: String, photos: [LibraryPhoto])] {
        var out: [(key: String, title: String, photos: [LibraryPhoto])] = []
        let calendar = Calendar.current
        for p in visiblePhotos {
            let key: String, title: String
            if sort == "film" {
                key = p.recipe.filmID
                title = model.filmName(for: key)
            } else {
                let date = sort == "shot" ? (p.capturedAt ?? p.createdAt) : p.createdAt
                if dense {
                    // Zoomed out: a section a month.
                    let month = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
                    key = "m" + String(month.timeIntervalSince1970)
                    title = month.formatted(.dateTime.year().month(.wide))
                    if out.last?.key == key { out[out.count - 1].photos.append(p) } else { out.append((key, title, [p])) }
                    continue
                }
                let day = calendar.startOfDay(for: date)
                key = String(day.timeIntervalSince1970)
                title = calendar.isDateInToday(day) ? "今天" : calendar.isDateInYesterday(day) ? "昨天"
                    // Date only: `.year(.omitted)` on a date style brought the time back ("0:00").
                    : calendar.isDate(day, equalTo: .now, toGranularity: .year)
                        ? day.formatted(.dateTime.month().day().weekday())
                        : day.formatted(.dateTime.year().month().day().weekday())
            }
            if out.last?.key == key { out[out.count - 1].photos.append(p) } else { out.append((key, title, [p])) }
        }
        return out
    }

    /// Hold a tile, then slide: every tile from it to the finger (in the wall's order) is selected, or
    /// deselected when the first one already was — as in Photos.
    /// shortcut: no auto-scroll at the screen's edge; lift, scroll and slide again.
    private func slideSelect(at point: CGPoint) {
        guard let hit = tileFrames.first(where: { $0.value.contains(point) })?.key else { return }
        if slide == nil {
            let order = sections.flatMap { $0.photos.map(\.id) }
            guard let i = order.firstIndex(of: hit) else { return }
            slide = SlideRun(order: order, anchor: i, adding: !selected.contains(hit), base: selected)
        }
        guard let run = slide, let i = run.order.firstIndex(of: hit) else { return }
        var range = Set(run.order[min(run.anchor, i)...max(run.anchor, i)])
        if let source = model.recipeSourcePhotoID { range.remove(source) }
        let next = run.adding ? run.base.union(range) : run.base.subtracting(range)
        if next != selected { selected = next }
    }

    private var wall: some View {
        LazyVGrid(columns: columns, spacing: 3, pinnedViews: [.sectionHeaders]) {
            ForEach(sections, id: \.key) { section in
                Section {
                    ForEach(section.photos) { photo in
                        wallTile(photo)
                    }
                } header: {
                    // A floating label, as Photos pins its dates: a full-width bar stuck at the top looked abrupt.
                    HStack {
                        HStack(spacing: 6) {
                            Text(section.title).font(.system(size: 13, weight: .semibold))
                            Text("\(section.photos.count) 张").font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.labCream.opacity(0.55))
                        }
                        .foregroundStyle(Color.labCream)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Color.labInk.opacity(0.35), in: Capsule())
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .coordinateSpace(.named("wall"))
        .gesture(SlideSelectRecognizer(enabled: selecting) { slideSelect(at: $0) } ended: { slide = nil })
    }

    private func wallTile(_ photo: LibraryPhoto) -> some View {
            Group {
                // While selecting, a long press starts a slide, not the menu.
                if selecting { photoTile(photo) } else {
                photoTile(photo)
                    .contextMenu {
                        Button {
                            Task { @MainActor in await model.openLibraryPhoto(photo.id) }
                        } label: {
                            Label("编辑", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            model.toggleFavorite(photo.id)
                        } label: {
                            Label(photo.favorite ? "取消收藏" : "收藏", systemImage: photo.favorite ? "heart.slash" : "heart")
                        }
                        Button {
                            copyRecipe(from: photo.id)
                        } label: {
                            Label("复制配方", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleteIDs = [photo.id]
                            showingDelete = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("wall")) } action: { tileFrames[photo.id] = $0 }
            .onDisappear { tileFrames[photo.id] = nil }
    }

    private func photoTile(_ photo: LibraryPhoto) -> some View {
        let isSelected = selected.contains(photo.id)
        let isRecipeSource = model.recipeSourcePhotoID == photo.id
        let shape = RoundedRectangle(cornerRadius: dense ? 1 : 4, style: .continuous)

        return Color.labPanel
            .aspectRatio(1, contentMode: .fit)
            // The picture in a layer of its own: filling the square, a wide photo is wider than the tile, and the
            // label laid out in the same ZStack started off the tile's left edge (the film name was cut).
            .overlay {
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .saturation(isRecipeSource ? 0.12 : 1)
            }
            .overlay {
                ZStack(alignment: .bottom) {
                    Group {
                        LinearGradient(colors: [.clear, .black.opacity(0.62)],
                                       startPoint: .center, endPoint: .bottom)
                        HStack(spacing: 4) {
                            if photo.isEdited {
                                Circle()
                                    .fill(Color.labRed.opacity(0.92))
                                    .frame(width: 4, height: 4)
                            }
                            if photo.captured {
                                Image(systemName: "camera.fill").font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            if photo.pair != nil {
                                Image(systemName: "rectangle.split.2x1.fill").font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            if photo.recipe.hdr == true {
                                Text("HDR").font(.system(size: 6.5, weight: .heavy)).foregroundStyle(Color.labRed)
                            }
                            if columnCount < 5 && !dense {
                            Text(model.shortFilmName(for: photo.recipe.filmID))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .padding(.bottom, 7)
                    }

                    if isSelected {
                        Color.labRed.opacity(0.10)
                    }
                    if isRecipeSource {
                        Color.black.opacity(selecting ? 0.34 : 0.24)
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(isSelected ? Color.labRed : Color.white.opacity(0.055),
                                   lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if photo.favorite && !dense {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(7)
                        .accessibilityLabel("已收藏")
                }
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    if isRecipeSource {
                        ZStack {
                            Circle().fill(Color.black.opacity(0.48))
                            Circle().strokeBorder(Color.white.opacity(0.40), lineWidth: 1)
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.82))
                        }
                        .frame(width: 22, height: 22)
                        .padding(6)
                    } else {
                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.labRed : Color.black.opacity(0.28))
                            Circle()
                                .strokeBorder(Color.white.opacity(isSelected ? 0 : 0.72), lineWidth: 1.5)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                        .padding(6)
                    }
                } else if isRecipeSource {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.46))
                        Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.78))
                    }
                    .frame(width: 22, height: 22)
                    .padding(6)
                } else if photo.isEdited && columnCount <= 4 {
                    Menu {
                        Button {
                            Task { @MainActor in await model.openLibraryPhoto(photo.id) }
                        } label: {
                            Label("编辑", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            copyRecipe(from: photo.id)
                        } label: {
                            Label("复制配方", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            deleteIDs = [photo.id]
                            showingDelete = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .labGlassInteractive(in: Circle())
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .topLeading) {
                if isRecipeSource {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 7, weight: .bold))
                        Text("配方来源")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Color.white.opacity(0.82))
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(Color.black.opacity(0.42), in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1)
                    }
                    .padding(6)
                }
            }
            .contentShape(shape)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(photo.name)
            .accessibilityValue(isRecipeSource ? "配方来源，已锁定"
                                : (isSelected ? "已选择" : ""))
            .onTapGesture {
                if selecting {
                    guard !isRecipeSource else { return }
                    if isSelected { selected.remove(photo.id) } else { selected.insert(photo.id) }
                } else {
                    Task { @MainActor in await model.openLibraryPhoto(photo.id) }
                }
            }
    }

    // MARK: - selection

    private var selectionBar: some View {
        VStack(spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.isEmpty ? "选择照片" : "已选 \(selected.count) 张")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.labCream)
                        .contentTransition(.numericText())
                    Text(model.clipboardRecipe == nil
                         ? "长按照片可复制配方"
                         : "配方来源已灰显锁定")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.labCream.opacity(0.40))
                }
                Spacer()
                let all = !selectablePhotoIDs.isEmpty && selected == selectablePhotoIDs
                Button {
                    selected = all ? [] : selectablePhotoIDs
                } label: {
                    Text(all ? "取消全选" : "全选")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.labCream)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 9) {
                if selected.count == 2 {
                    Button {
                        let ids = model.library.map(\.id).filter { selected.contains($0) }
                        // The wall is newest first; a strip reads left to right, oldest first.
                        pairing = PairSpec(left: ids[1], right: ids[0])
                    } label: {
                        Label("做成双拼", systemImage: "rectangle.split.2x1")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .frame(height: 46)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(Color.labCream.opacity(0.88))
                    }
                    .buttonStyle(.plain)
                }
                if selected.count == 1, let id = selected.first {
                    Button {
                        copyRecipe(from: id)
                    } label: {
                        Label("复制配方", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .frame(height: 46)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(Color.labCream.opacity(0.88))
                    }
                    .buttonStyle(.plain)
                }

                if !model.savedRecipes.isEmpty {
                    recipeMenu {
                        let ids = selected
                        await model.applyRecipe($0.recipe, to: ids)
                        selected.removeAll()
                        selecting = false
                    }
                    .disabled(selected.isEmpty)
                }

                Button {
                    paste()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.on.clipboard")
                        Text(model.clipboardRecipe == nil ? "先复制一个配方" : "粘贴配方")
                        if let recipe = model.clipboardRecipe {
                            Text("· \(model.filmName(for: recipe.filmID))")
                                .lineLimit(1)
                                .font(.system(size: 10, weight: .medium))
                                .opacity(0.62)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(model.clipboardRecipe == nil
                                ? Color.white.opacity(0.07)
                                : Color.labRed.opacity(0.28),
                                in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(model.clipboardRecipe == nil ? 0.05 : 0.16),
                                    lineWidth: 1)
                    }
                    .foregroundStyle(model.clipboardRecipe == nil ? Color.white.opacity(0.42) : .white)
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty || model.clipboardRecipe == nil)

                Button {
                    deleteIDs = selected
                    showingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(selected.isEmpty ? Color.white.opacity(0.08) : Color.red.opacity(0.22), in: Circle())
                        .foregroundStyle(selected.isEmpty ? Color.labCream.opacity(0.35) : Color(red: 1, green: 0.55, blue: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty)
            }
        }
        .padding(14)
        // A dark base under the glass: over bright photos the glass alone washed the buttons out.
        .background(Color.labInk.opacity(0.72), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .labGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.36), radius: 26, y: 12)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Selection in the 系统相册 view: the picked photos are linked when an action needs them.
    private var photosSelectionBar: some View {
        let count = selectedAssets.count
        return HStack(spacing: 9) {
            Text(count == 0 ? "选择照片" : "已选 \(count) 张")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.labCream)
                .contentTransition(.numericText())
            Spacer(minLength: 4)
            if count == 2 {
                barAction("做成双拼", "rectangle.split.2x1") {
                    let ids = await model.linkAssets(selectedAssets)
                    if ids.count == 2 { pairing = PairSpec(left: ids[0], right: ids[1]) }
                }
            }
            if count == 1 {
                barAction("复制配方", "doc.on.doc") {
                    if let id = await model.linkAssets(selectedAssets).first { model.copyRecipe(from: id) }
                    selectedAssets.removeAll()
                }
            }
            if !model.savedRecipes.isEmpty {
                recipeMenu {
                    let ids = await model.linkAssets(selectedAssets)
                    await model.applyRecipe($0.recipe, to: Set(ids))
                    selectedAssets.removeAll()
                    selecting = false
                }
                .disabled(count == 0)
            }
            barAction(model.clipboardRecipe == nil ? "先复制配方" : "粘贴配方", "doc.on.clipboard") {
                let ids = await model.linkAssets(selectedAssets)
                await model.pasteRecipe(to: Set(ids))
                selectedAssets.removeAll()
                selecting = false
            }
            .disabled(count == 0 || model.clipboardRecipe == nil)
            .opacity(count == 0 || model.clipboardRecipe == nil ? 0.4 : 1)
        }
        .padding(14)
        .labGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.36), radius: 26, y: 12)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Saved looks to put on the selection.
    private func recipeMenu(_ apply: @escaping @MainActor (SavedRecipe) async -> Void) -> some View {
        Menu {
            Section("套用配方") {
                ForEach(model.savedRecipes) { saved in
                    Button { Task { @MainActor in await apply(saved) } } label: {
                        Label { Text(saved.name); Text(model.filmName(for: saved.recipe.filmID)) } icon: {
                            Image(systemName: "wand.and.stars")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(Color.white.opacity(0.08), in: Circle())
                .foregroundStyle(Color.labCream.opacity(0.85))
        }
        .accessibilityLabel("套用配方")
    }

    private func barAction(_ title: String, _ symbol: String, _ run: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { @MainActor in await run() } } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color.white.opacity(0.08), in: Capsule())
                .foregroundStyle(Color.labCream.opacity(0.88))
        }
        .buttonStyle(.plain)
    }

    private func copyRecipe(from id: UUID) {
        selected.remove(id)
        model.copyRecipe(from: id)
    }

    private func paste() {
        guard !selected.isEmpty, model.clipboardRecipe != nil else { return }
        let ids = selected.intersection(selectablePhotoIDs)
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            await model.pasteRecipe(to: ids)
            selected.removeAll()
            selecting = false
        }
    }

    // MARK: - empty, busy, toast

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.labRed.opacity(0.12))
                    .frame(width: 164, height: 164)
                    .blur(radius: 30)
                Circle()
                    .fill(Color.white.opacity(0.035))
                    .frame(width: 108, height: 108)
                Circle()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    .frame(width: 108, height: 108)
                Image(systemName: "photo.stack")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color.labCream.opacity(0.86))
            }
            .frame(height: 172)

            VStack(spacing: 8) {
                Text("把一组照片带进来")
                    .font(.title2.weight(.semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.labCream)
                Text("点开一张开始调色，返回后就是照片墙。\n长按照片复制配方，多选后一键粘贴。")
                    .font(.footnote)
                    .foregroundStyle(Color.labCream.opacity(0.44))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            VStack(spacing: 10) {
                PhotosPicker(selection: $pickerItems,
                             maxSelectionCount: 100,
                             matching: .images,
                             photoLibrary: .shared()) {
                    Label("从相册添加照片", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(.white)
                        .labGlassTint(Color.labRed.opacity(0.16), in: Capsule())
                }
                .tint(Color.labCream)

                Button {
                    showingFileImporter = true
                } label: {
                    Label("从文件导入 RAW / JPEG", systemImage: "folder.badge.plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.labCream.opacity(0.82))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .labGlassInteractive(in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 310)
            .padding(.top, 28)

            Text("支持 Sony ARW · DNG · JPEG · HEIC")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.labCream.opacity(0.28))
                .padding(.top, 14)
        }
        .padding(.top, 20)
        .frame(minHeight: 500)
        .frame(maxWidth: .infinity)
    }

    private func busyOverlay(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.20).ignoresSafeArea()
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(Color.labCream)
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.labCream)
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 58)
            .labGlass(in: Capsule())
            .shadow(color: .black.opacity(0.32), radius: 24, y: 10)
        }
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.labCream)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 17)
            .frame(minHeight: 40)
            .labGlass(in: Capsule())
            .shadow(color: .black.opacity(0.32), radius: 20, y: 8)
        .allowsHitTesting(false)
    }
}

/// Slide across the wall to select (as in Photos): a pan that starts sideways selects at once; one that starts up
/// or down is the scroll view's. While selecting, a finger near the top or bottom edge scrolls the wall on.
/// UIKit, not a SwiftUI drag: a drag gesture inside the scroll view took every touch on iOS 27.
struct SlideSelectRecognizer: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var moved: (CGPoint) -> Void
    var ended: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let r = UIPanGestureRecognizer()
        r.delegate = context.coordinator
        r.maximumNumberOfTouches = 1
        return r
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
        context.coordinator.moved = moved
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let c = context.coordinator
        switch recognizer.state {
        case .began, .changed:
            let wall = context.converter.location(in: .named("wall"))
            let local = recognizer.location(in: recognizer.view)
            c.offset = CGPoint(x: wall.x - local.x, y: wall.y - local.y)   // the wall in the recognizer's view
            c.track(recognizer)
            moved(wall)
        default:
            c.stop()
            ended()
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var moved: (CGPoint) -> Void = { _ in }
        var offset = CGPoint.zero
        private weak var recognizer: UIPanGestureRecognizer?
        private var link: CADisplayLink?

        /// Sideways first, or it is a scroll.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        /// The scroll view's pan waits until a sideways start has been ruled out.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }

        func track(_ r: UIPanGestureRecognizer) {
            recognizer = r
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }

        func stop() { link?.invalidate(); link = nil }

        /// Near an edge of the visible wall: scroll that way, faster the closer the finger, and select on.
        @objc private func tick() {
            guard let r = recognizer, let view = r.view, let scroll = Self.scrollView(above: view) else { return }
            let y = r.location(in: scroll).y - scroll.contentOffset.y        // in the visible frame
            let band: CGFloat = 80
            let top = scroll.adjustedContentInset.top, bottom = scroll.bounds.height - scroll.adjustedContentInset.bottom
            var step: CGFloat = 0
            if y < top + band { step = -(top + band - y) / band * 14 }
            else if y > bottom - band { step = (y - (bottom - band)) / band * 14 }
            guard step != 0 else { return }
            let minY = -scroll.adjustedContentInset.top
            let maxY = max(minY, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            let next = min(max(scroll.contentOffset.y + step, minY), maxY)
            guard next != scroll.contentOffset.y else { return }
            scroll.contentOffset.y = next
            let local = r.location(in: view)
            moved(CGPoint(x: local.x + offset.x, y: local.y + offset.y))
        }

        private static func scrollView(above view: UIView) -> UIScrollView? {
            var v: UIView? = view
            while let s = v { if let scroll = s as? UIScrollView { return scroll }; v = s.superview }
            return nil
        }
    }
}
