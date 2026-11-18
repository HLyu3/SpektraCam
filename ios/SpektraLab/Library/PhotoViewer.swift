//  PhotoViewer.swift — 查看: a tap on the wall shows the developed photo, as Photos does; 编辑 opens the editor.
//  Swipe through the wall in its own order (filter and sort), pinch or double-tap to zoom, hold to see the original.
//  `PhotoCompare`: two selected photos one over the other (side by side when the phone is turned), zoomed together.
//
//  The picture is the wall's thumbnail at once, then the 2048 px develop the light table keeps (`largeDevelop`).

import SwiftUI

struct PhotoViewer: View {
    @ObservedObject var model: ViewModel
    let ids: [UUID]
    @State var current: UUID
    let edit: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chrome = true
    @State private var exportQuestion: UUID?
    // Paging is our own (a horizontal drag at 1×): a page TabView never swiped — the pictures' own gestures
    // (zoom, pan, hold) took every touch from its scroll view.
    @State private var dragX: CGFloat = 0
    /// The current page's zoom, as its scroll view reports it (`ZoomingImage`): above 1 the page pans, not pages.
    @State private var zoom: CGFloat = 1
    /// Bumped to put the current page back to 1× (a page change).
    @State private var unzoom = 0
    @GestureState private var holding = false
    @State private var large: [UUID: UIImage] = [:]
    @State private var originals: [UUID: UIImage] = [:]
    @State private var opening = false

    private var index: Int { ids.firstIndex(of: current) ?? 0 }
    private var photo: LibraryPhoto? { model.library.first { $0.id == current } }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack {
                ForEach(max(index - 1, 0)...min(index + 1, ids.count - 1), id: \.self) { i in
                    page(ids[i], size: proxy.size, isCurrent: i == index)
                        .offset(x: CGFloat(i - index) * (w + 16) + dragX)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { g in
                    guard !holding, zoom <= 1.01 else { return }
                    // Resist past the first and the last.
                    let edge = (index == 0 && g.translation.width > 0) || (index == ids.count - 1 && g.translation.width < 0)
                    dragX = edge ? g.translation.width / 3 : g.translation.width
                }
                .onEnded { g in
                    guard zoom <= 1.01 else { dragX = 0; return }
                    let swipe = g.predictedEndTranslation.width
                    var next = index
                    if swipe < -w / 3, index < ids.count - 1 { next += 1 }
                    if swipe > w / 3, index > 0 { next -= 1 }
                    withAnimation(.easeOut(duration: 0.22)) {
                        dragX = CGFloat(index - next) * (w + 16)
                    } completion: {
                        current = ids[next]
                        dragX = 0
                    }
                })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.3).sequenced(before: DragGesture(minimumDistance: 0))
                .updating($holding) { value, state, _ in if case .second(true, _) = value { state = true } })
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { if chrome { topBar } }
        .overlay(alignment: .bottom) { if chrome { bottomBar } }
        // What the picture is: the wall's small one until the sharp develop lands, and a screen-sized develop when zoomed
        // (the export is full size).
        // Under the top bar: at the bottom the bar and the home indicator covered it.
        .overlay(alignment: .top) {
            let note = large[current] == nil ? String(localized: "清晰版冲洗中…") : zoom > 1.5 ? String(localized: "预览图放大会略模糊，导出是原图全尺寸") : nil
            if let note, !holding {
                Text(note).font(.caption2.weight(.medium)).foregroundStyle(Color.labCream.opacity(0.85))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, chrome ? 56 : 12)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if holding {
                Text(originals[current] == nil ? String(localized: "原图载入中…") : String(localized: "原图"))
                    .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(height: 24)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 70)
            }
        }
        .statusBarHidden(!chrome)
        .preferredColorScheme(.dark)
        .onChange(of: current) { _, _ in resetZoom() }
        .onChange(of: holding) { _, on in
            let id = current
            if on, originals[id] == nil { Task { originals[id] = await model.originalPreview(for: id) } }
        }
        // The page shown first, then its neighbours, so a swipe lands on a sharp picture.
        .task(id: current) {
            let i = index
            for j in [i, i + 1, i - 1] where ids.indices.contains(j) && large[ids[j]] == nil {
                if let image = await model.largeDevelop(for: ids[j]) { large[ids[j]] = image }
            }
        }
        .confirmationDialog(String(localized: "导出这张？"), isPresented: Binding(get: { exportQuestion != nil }, set: { if !$0 { exportQuestion = nil } }),
                            titleVisibility: .visible) {
            let id = exportQuestion.map { [$0] } ?? []
            if model.previousPrints(of: id).count > 0 {
                Button(String(localized: "导出，替换旧的成片")) { run(id, replacing: true) }
                Button(String(localized: "导出，旧成片也保留")) { run(id, replacing: false) }
            } else {
                Button(String(localized: "导出")) { run(id, replacing: false) }
            }
            Button(String(localized: "取消"), role: .cancel) { exportQuestion = nil }
        } message: {
            let before = model.previousPrints(of: exportQuestion.map { [$0] } ?? [])
            Text((before.count == 0 ? String(localized: "还没导出过。") : before.changed > 0 ? String(localized: "已经导出过，之后又改过，新成片会和旧的不一样。") : String(localized: "已经导出过，之后没改过。"))
                 + String(localized: "存到“照片”，格式：\(model.exportOptions.format.title) · \(model.exportOptions.colorSpace.title)。"))
        }
    }

    private func openEditor() {
        let id = current
        opening = true
        Task { @MainActor in
            await Task.yield()                     // the spinner shows before the photo starts to load
            await model.openLibraryPhoto(id)
            opening = false
            if model.editingPhotoID == id { dismiss() } else { NSLog("SpektraLab viewer: the editor did not open %@", id.uuidString) }
        }
    }

    private func resetZoom() { zoom = 1; unzoom += 1 }

    /// One photo: its develop (the thumbnail until the large one lands); the current one zoomed, or held for its original.
    @ViewBuilder private func page(_ id: UUID, size: CGSize, isCurrent: Bool) -> some View {
        let thumb = model.library.first { $0.id == id }?.thumbnail
        let image = isCurrent && holding ? (originals[id] ?? large[id] ?? thumb) : (large[id] ?? thumb)
        if let image {
            if isCurrent {
                ZoomingImage(image: image, zoom: $zoom, reset: unzoom,
                             tap: { withAnimation(.easeOut(duration: 0.15)) { chrome.toggle() } })
                    .frame(width: size.width, height: size.height)
            } else {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    private func run(_ ids: [UUID], replacing: Bool) {
        exportQuestion = nil
        Task { @MainActor in _ = await model.exportPhotos(ids, replacingOld: replacing) }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let p = photo {
                    Text(model.filmName(for: p.recipe.filmID)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(p.recipe.noFilm == true ? String(localized: "原图") : String(localized: "相纸 · ") + model.filmName(for: p.recipe.printStock))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            // The editor opens first, under this cover, and the cover goes once it is there: dismissing first and
            // opening after a delay left the wall showing with no editor.
            Button { openEditor() } label: { if opening { ProgressView() } else { Text(String(localized: "编辑")) } }
                .disabled(opening)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 34)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
        .foregroundStyle(Color.labCream)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var bottomBar: some View {
        HStack {
            if let p = photo {
                Button { model.toggleFavorite(p.id) } label: {
                    Image(systemName: p.favorite ? "heart.fill" : "heart").frame(width: 44, height: 44)
                }
                Spacer()
                Text((p.capturedAt ?? p.createdAt).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button { model.copyRecipe(from: p.id) } label: { Label(String(localized: "复制配方"), systemImage: "doc.on.doc") }
                    if let r = model.clipboardRecipe, model.recipeSourcePhotoID != p.id {
                        Button { Task { @MainActor in await model.pasteRecipe(to: [p.id]) } } label: {
                            Label(String(localized: "粘贴配方 · \(model.filmName(for: r.filmID))"), systemImage: "doc.on.clipboard")
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                Button { exportQuestion = p.id } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }
            }
        }
        .font(.system(size: 18))
        .foregroundStyle(Color.labCream)
        .padding(.horizontal, 16)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }
}

/// Two photos, zoomed and panned together: one over the other, side by side when the screen is wider than tall.
struct PhotoCompare: View {
    @ObservedObject var model: ViewModel
    let ids: [UUID]
    @Environment(\.dismiss) private var dismiss
    @State private var images: [UUID: UIImage] = [:]
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var area: CGSize = .zero

    /// The pan held so a pane's picture (about the pane's size) never leaves its edge for black.
    private func held(_ o: CGSize) -> CGSize {
        let wide = area.width > area.height
        let pane = wide ? CGSize(width: area.width / 2, height: area.height) : CGSize(width: area.width, height: area.height / 2)
        let mx = pane.width * (zoom - 1) / 2, my = pane.height * (zoom - 1) / 2
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
            layout {
                ForEach(ids, id: \.self) { id in pane(id) }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { area = $0 }
        .background(Color.black.ignoresSafeArea())
        .gesture(MagnifyGesture()
            .onChanged { zoom = min(max(baseZoom * $0.magnification, 1), 8); offset = held(offset) }
            .onEnded { _ in baseZoom = zoom; baseOffset = offset })
        .simultaneousGesture(DragGesture()
            .onChanged { offset = held(CGSize(width: baseOffset.width + $0.translation.width, height: baseOffset.height + $0.translation.height)) }
            .onEnded { _ in baseOffset = offset })
        .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2.5; baseZoom = zoom; offset = .zero; baseOffset = .zero } }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(Color.labCream).padding(12)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            for id in ids where images[id] == nil {
                if let image = await model.largeDevelop(for: id) { images[id] = image }
            }
        }
    }

    private func pane(_ id: UUID) -> some View {
        let p = model.library.first { $0.id == id }
        return ZStack(alignment: .bottomLeading) {
            Color.black
            if let image = images[id] ?? p?.thumbnail {
                Image(uiImage: image).resizable().scaledToFit().scaleEffect(zoom).offset(offset)
            }
            if let p {
                Text(model.filmName(for: p.recipe.filmID) + (p.recipe.noFilm == true ? "" : " · " + model.filmName(for: p.recipe.printStock)))
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.labCream)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(.ultraThinMaterial, in: Capsule()).padding(10)
            }
        }
        .clipped()
    }
}


/// A picture in a UIScrollView, as Photos zooms: pinch about the fingers, two fingers pan while pinching, the edges
/// bounce instead of showing black, double-tap zooms in about the tap. At 1× it takes no one-finger drag, so the
/// viewer's own swipe pages.
struct ZoomingImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoom: CGFloat
    /// A new value puts it back to 1×.
    let reset: Int
    let tap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Lays the picture out whenever its size is known or changes. Laid out only from SwiftUI's update, a new page
    /// came up before it had a size: the image view stood at the picture's pixel size and the page showed a corner
    /// of it, "suddenly zoomed".
    final class Scroller: UIScrollView {
        var onLayout: ((UIScrollView) -> Void)?
        private var laidFor: CGSize = .zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != laidFor { laidFor = bounds.size; onLayout?(self) }
        }
    }

    func makeUIView(context: Context) -> UIScrollView {
        let v = Scroller()
        v.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layout($0) }
        v.delegate = context.coordinator
        v.minimumZoomScale = 1
        v.maximumZoomScale = 8
        v.bouncesZoom = true
        v.showsHorizontalScrollIndicator = false
        v.showsVerticalScrollIndicator = false
        v.contentInsetAdjustmentBehavior = .never
        v.backgroundColor = .clear
        v.isScrollEnabled = false
        let iv = UIImageView(image: image)
        iv.frame = .zero                      // sized by `layout` once the view has its bounds
        iv.contentMode = .scaleAspectFit
        v.addSubview(iv)
        context.coordinator.imageView = iv
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        v.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        single.require(toFail: double)
        v.addGestureRecognizer(single)
        return v
    }

    func updateUIView(_ v: UIScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.imageView?.image !== image {
            c.imageView?.image = image
            if v.zoomScale != 1 { v.setZoomScale(1, animated: false) }   // a new picture starts whole
        }
        if c.lastReset != reset { c.lastReset = reset; v.setZoomScale(1, animated: false) }
        c.layout(v)
    }

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomingImage
        weak var imageView: UIImageView?
        var lastReset: Int
        init(_ p: ZoomingImage) { parent = p; lastReset = p.reset }

        /// The image's aspect-fit frame at 1×, and centred while it is smaller than the view.
        func layout(_ v: UIScrollView) {
            guard let iv = imageView, let img = iv.image, v.bounds.width > 0 else { return }
            if v.zoomScale == 1 {
                let k = min(v.bounds.width / img.size.width, v.bounds.height / img.size.height)
                let size = CGSize(width: img.size.width * k, height: img.size.height * k)
                iv.frame = CGRect(origin: .zero, size: size)
                v.contentSize = size
            }
            let w = iv.frame.width, h = iv.frame.height
            v.contentInset = UIEdgeInsets(top: max(0, (v.bounds.height - h) / 2), left: max(0, (v.bounds.width - w) / 2),
                                          bottom: 0, right: 0)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ v: UIScrollView) {
            layout(v)
            v.isScrollEnabled = v.zoomScale > 1.01
            if abs(parent.zoom - v.zoomScale) > 0.01 { parent.zoom = v.zoomScale }
        }

        func scrollViewDidEndZooming(_ v: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            v.isScrollEnabled = scale > 1.01
            parent.zoom = scale
        }

        @objc func tapped() { parent.tap() }

        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? UIScrollView, let iv = imageView else { return }
            if v.zoomScale > 1.01 {
                v.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: iv), s: CGFloat = 2.5
                let size = CGSize(width: v.bounds.width / s, height: v.bounds.height / s)
                v.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
