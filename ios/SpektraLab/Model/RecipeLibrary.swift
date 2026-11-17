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
        guard let data = try? Data(contentsOf: recipesURL),
              let list = try? JSONDecoder().decode([SavedRecipe].self, from: data) else { return }
        savedRecipes = list
        favoriteFilms = UserDefaults.standard.stringArray(forKey: Self.favoriteFilmsKey) ?? []
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
            // A combination saved before 相机测光 never chose a meter: its shots meter as a new photo does (a
            // 均衡 shot on such a roll blew a room out). A meter chosen for it is kept.
            var look = saved.recipe
            if look.exposureMethod == nil { look.exposureMethod = PhotoRecipe.newPhotoMeter }
            return look
        }
        var look = newPhotoRecipe
        look.noFilm = nil          // a film roll: the new-photo look is 无胶片 by default, the roll is not
        // A camera shot develops at the camera's own exposure (相机测光), whatever the new-photo look's meter.
        look.exposureMethod = PhotoRecipe.newPhotoMeter
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
