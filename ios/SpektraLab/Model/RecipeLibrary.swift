//  RecipeLibrary.swift — named looks the person keeps (配方), and the films they favour.
//  A roll in the camera is a film id, "" (no film) or "recipe:<id>" (a saved look).

import Foundation

struct SavedRecipe: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var recipe: PhotoRecipe
    var created = Date()

    var roll: String { "recipe:" + id.uuidString }
}

extension ViewModel {
    private var recipesURL: URL { libraryRootURL.appendingPathComponent("recipes.json") }
    static let favoriteFilmsKey = "SpektraLab.favoriteFilms"

    func loadSavedRecipes() {
        favoriteFilms = UserDefaults.standard.stringArray(forKey: Self.favoriteFilmsKey) ?? []
        if let data = try? Data(contentsOf: recipesURL),
           let list = try? JSONDecoder().decode([SavedRecipe].self, from: data) { savedRecipes = list }
        seedBuiltInCombinations()
    }

    private static let builtInSeededKey = "SpektraLab.builtInCombinations.v1"

    /// The combinations the app comes with, so a new shelf shows that a film and a paper can be kept together
    /// (the owner's first one: Portra 400 on Portra Endura, the engine's calibrated minilab pair, metered as the camera
    /// does). Added once — a deleted one stays deleted — and not twice when the shelf already holds that pair.
    private func seedBuiltInCombinations() {
        guard !UserDefaults.standard.bool(forKey: Self.builtInSeededKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.builtInSeededKey)
        var look = PhotoRecipe.standard
        look.noFilm = nil
        look.filmStock = "kodak_portra_400"
        look.printStock = "kodak_portra_endura"
        look.exposureMethod = nil          // a combination with no meter shoots as the camera metered (`rollRecipe`)
        guard !savedRecipes.contains(where: { $0.recipe.filmStock == look.filmStock && $0.recipe.printStock == look.printStock })
        else { return }
        savedRecipes.append(SavedRecipe(name: "Portra 400 · Professional Portra", recipe: look))
        storeSavedRecipes()
    }

    private func storeSavedRecipes() {
        if let data = try? JSONEncoder().encode(savedRecipes) { try? data.write(to: recipesURL, options: .atomic) }
    }

    /// Keep the look on the canvas under a name.
    @discardableResult
    func saveCurrentRecipe(named name: String) -> SavedRecipe {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let saved = SavedRecipe(name: trimmed.isEmpty ? currentLookName : trimmed, recipe: currentRecipe)
        savedRecipes.insert(saved, at: 0)
        storeSavedRecipes()
        libraryMessage = "已存为配方「\(saved.name)」"
        return saved
    }

    /// Keep a film + paper combination from the camera (a roll's whole look) under a name; it joins the roll shelf.
    @discardableResult
    func saveCombination(_ look: PhotoRecipe, named name: String) -> SavedRecipe {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let fallback = "\(shortFilmName(for: look.filmStock)) · \(shortFilmName(for: look.printStock))"
        let saved = SavedRecipe(name: trimmed.isEmpty ? fallback : trimmed, recipe: look)
        savedRecipes.insert(saved, at: 0)
        storeSavedRecipes()
        return saved
    }

    func renameRecipe(_ id: UUID, to name: String) {
        guard let i = savedRecipes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        savedRecipes[i].name = trimmed
        storeSavedRecipes()
    }

    func deleteRecipe(_ id: UUID) {
        savedRecipes.removeAll { $0.id == id }
        storeSavedRecipes()
    }

    func toggleFavoriteFilm(_ id: String) {
        if let i = favoriteFilms.firstIndex(of: id) { favoriteFilms.remove(at: i) } else { favoriteFilms.append(id) }
        UserDefaults.standard.set(favoriteFilms, forKey: Self.favoriteFilmsKey)
    }

    /// Films in the order a picker offers them: favourites first, the rest as the catalogue has them.
    var filmsFavouritesFirst: [Stock] {
        films.filter { favoriteFilms.contains($0.id) } + films.filter { !favoriteFilms.contains($0.id) }
    }

    /// The whole look a roll develops with: a saved recipe as it is, or a film with its own paper on
    /// the new-photo look. Nil for no film.
    /// `paper`: one chosen in the camera's 冲印 menu for this visit (else the film's recommended paper).
    func rollRecipe(_ roll: String, paper chosen: String? = nil) -> PhotoRecipe? {
        if roll.isEmpty { return nil }
        if roll.hasPrefix("recipe:"), let id = UUID(uuidString: String(roll.dropFirst(7))),
           let saved = savedRecipes.first(where: { $0.id == id }) {
            // A combination's own meter, if one was chosen; none meters as a camera shot does (保高光).
            var look = saved.recipe
            if look.exposureMethod == nil { look.exposureMethod = PhotoRecipe.shotMeter }
            return look
        }
        var look = newPhotoRecipe
        look.noFilm = nil          // a film roll: the new-photo look is 无胶片 by default, the roll is not
        // A camera shot meters 保高光 (the owner, 2026-11-17, as the official app's shots look: the sky held); imports
        // keep the Mac's 均衡. 相机 and 均衡 stay choices in 曝光.
        look.exposureMethod = PhotoRecipe.shotMeter
        look.filmStock = films.contains { $0.id == roll } ? roll : StockCatalog.defaultFilm
        look.printStock = chosen.flatMap { catalog.canPrint(film: look.filmStock, on: $0) ? $0 : nil }
            ?? paper(for: look.filmStock)     // as the editor picks it for this film
        return look
    }

    func rollTitle(_ roll: String) -> String {
        if roll.isEmpty { return "无胶卷" }
        if roll.hasPrefix("recipe:"), let id = UUID(uuidString: String(roll.dropFirst(7))),
           let saved = savedRecipes.first(where: { $0.id == id }) {
            return saved.name
        }
        return filmName(for: roll)
    }

    /// Put a saved look on the photo in the editor (undoable; the crop stays the photo's).
    func applySavedRecipe(_ saved: SavedRecipe) {
        edit { $0 = saved.recipe }
    }
}
