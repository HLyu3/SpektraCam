//  RecipesView.swift — 配方与胶片 (Settings): the saved looks and the films, in one place. A recipe or a film can be put in the
//  camera (`SpektraLab.cameraRoll`, the camera's roll), renamed or deleted; a film starred or not. Applying a
//  look to photos stays in the library's selection (it needs the photos).

import SwiftUI

struct RecipesView: View {
    @ObservedObject var model: ViewModel
    @AppStorage("SpektraLab.cameraRoll") private var roll = StockCatalog.defaultFilm
    @State private var renaming: SavedRecipe?
    @State private var newName = ""
    @State private var toast: String?

    private var kinds: [(String, [Stock])] {
        [("彩色负片", model.films.filter { !$0.monochrome && $0.type == .negative }),
         ("反转片", model.films.filter { $0.type == .positive }),
         ("黑白负片", model.films.filter(\.monochrome))].filter { !$0.1.isEmpty }
    }

    var body: some View {
            List {
                Section {
                    if model.savedRecipes.isEmpty {
                        Text("在编辑页的 ⋯ 里“存为配方”，这里就会出现。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(model.savedRecipes) { saved in
                        row(title: saved.name,
                            detail: "\(model.filmName(for: saved.recipe.filmStock)) · \(model.filmName(for: saved.recipe.printStock))",
                            symbol: "wand.and.stars", loaded: roll == saved.roll) { load(saved.roll, saved.name) }
                        .contextMenu {
                            Button { load(saved.roll, saved.name) } label: { Label("装进相机", systemImage: "camera") }
                            Button { newName = saved.name; renaming = saved } label: { Label("重命名", systemImage: "pencil") }
                            Button(role: .destructive) { model.deleteRecipe(saved.id) } label: { Label("删除", systemImage: "trash") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.deleteRecipe(saved.id) } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                } header: { Text("我的配方 · \(model.savedRecipes.count)") }

                let favourites = model.films.filter { model.favoriteFilms.contains($0.id) }
                if !favourites.isEmpty {
                    Section("收藏的胶片") { ForEach(favourites) { film($0) } }
                }
                ForEach(kinds, id: \.0) { title, stocks in
                    Section("\(title) · \(stocks.count)") { ForEach(stocks) { film($0) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LabBackdrop())
            .navigationTitle("配方与胶片")
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.footnote.weight(.semibold)).padding(.horizontal, 14).frame(height: 36)
                        .labGlass(in: Capsule()).padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert("重命名配方", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名字", text: $newName)
                Button("取消", role: .cancel) { renaming = nil }
                Button("好") { if let r = renaming { model.renameRecipe(r.id, to: newName) }; renaming = nil }
            }
        .tint(Color.labRed)
    }

    private func film(_ stock: Stock) -> some View {
        let starred = model.favoriteFilms.contains(stock.id)
        return row(title: stock.name, detail: nil, artwork: stock, loaded: roll == stock.id) { load(stock.id, stock.name) }
            .swipeActions(edge: .leading) {
                Button { model.toggleFavoriteFilm(stock.id) } label: { Label(starred ? "取消收藏" : "收藏", systemImage: starred ? "star.slash" : "star") }
                    .tint(Color.labRed)
            }
            .contextMenu {
                Button { load(stock.id, stock.name) } label: { Label("装进相机", systemImage: "camera") }
                Button { model.toggleFavoriteFilm(stock.id) } label: { Label(starred ? "取消收藏" : "收藏", systemImage: starred ? "star.slash" : "star") }
            }
    }

    private func row(title: String, detail: String?, symbol: String? = nil, artwork: Stock? = nil, loaded: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let artwork { StockArtwork(stock: artwork).frame(width: 30, height: 38) }
                else if let symbol { Image(systemName: symbol).frame(width: 30, height: 38).foregroundStyle(Color.labRed) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.labCream)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let artwork, model.favoriteFilms.contains(artwork.id) {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.labRed)
                }
                if loaded {
                    Label("在相机里", systemImage: "camera.fill").labelStyle(.iconOnly).foregroundStyle(Color.labRed)
                }
            }
        }
        .listRowBackground(Color.labPanel.opacity(0.6))
    }

    private func load(_ newRoll: String, _ name: String) {
        roll = newRoll
        withAnimation { toast = "相机装上了 \(name)" }
        Task { try? await Task.sleep(for: .seconds(2)); withAnimation { toast = nil } }
    }
}
