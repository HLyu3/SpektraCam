//  StockCatalog.swift — the films and papers the engine ships with.
//
//  A "stock" is a profile file: `<resources>/profiles/<stock>.json`, each with
//  an `info` block that names it, says whether it is a film or a paper, and
//  says whether it is a negative or a slide (positive) stock.
//
//  Two directories, one catalogue:
//
//  * `profiles/` — the 28 measured configurations from Andrea Volpato's
//    spektrafilm, 18 negative films + 4 slides + 6 papers.
//  * `../resources_product/profiles/` — 4 black-and-white films plus a
//    CineStill and a paper, measured for this project and shipped separately
//    because they are not upstream's.
//
//  The engine resolves a stock by name against `<resources>/profiles/`, so
//  the product profiles are merged into the same directory in the bundle. See
//  `ios/Tools/build-engine.sh`.
//
//  The catalogue is read at launch and cached: the files are small (a few
//  hundred kB each), the count is fixed, and the engine reads them again
//  anyway when it loads a profile.

import Foundation

/// One film or paper.
struct Stock: Identifiable, Hashable, Sendable {
    /// The profile's stem — what the engine calls it.
    let id: String
    /// The name to show a person: "Kodak Portra 400".
    let name: String
    /// `film` or `paper`.
    let support: Support
    /// `negative` or `positive`. A slide has no negative to print from.
    let type: FilmType
    /// The Mac catalogue's photographed film box, when one is available.
    let coverURL: URL?
    /// One silver emulsion (`channel_model: bw`): a black-and-white film or paper.
    var monochrome = false
    /// The paper the profile was made to print on.
    var targetPrint: String? = nil

    enum Support: String, Sendable {
        case film, paper
        var label: String {
            switch self {
            case .film: "胶片"
            case .paper: "相纸"
            }
        }
    }

    enum FilmType: String, Sendable {
        case negative, positive
        var label: String {
            switch self {
            case .negative: "负片"
            case .positive: "反转片"
            }
        }
    }

    /// Whether this stock can be printed: a slide film's `spk_render_digital_
    /// intermediate` has none, and the engine refuses it with `SPK_ERR_USER`.
    var isPrintable: Bool { type == .negative }
}

/// Every stock the bundle carries.
struct StockCatalog: Sendable {
    let films: [Stock]
    let papers: [Stock]
    let slides: [Stock]

    /// Every film that can be printed, negative and slide alike.
    var printableFilms: [Stock] { films }

    /// The catalogue, read from `resources/profiles`.
    ///
    /// A missing or malformed profile is skipped rather than fatal: one bad
    /// file should cost one stock, not the whole app.
    static func load(resources: URL) -> StockCatalog {
        let dir = resources.appendingPathComponent("profiles")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var films: [Stock] = []
        var papers: [Stock] = []
        var slides: [Stock] = []

        for file in files where file.hasSuffix(".json") {
            let id = String(file.dropLast(5))
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = json["info"] as? [String: Any],
                  let supportRaw = (info["support"] as? String)
                    ?? (json["derived_from"] != nil ? "film" : nil),
                  let typeRaw = (info["type"] as? String)
                    ?? (json["derived_from"] != nil ? "negative" : nil),
                  let support = Stock.Support(rawValue: supportRaw),
                  let type = Stock.FilmType(rawValue: typeRaw) else {
                continue
            }
            let name = (info["name"] as? String) ?? id
            let cover = resources
                .appendingPathComponent("film_covers")
                .appendingPathComponent(id)
                .appendingPathExtension("jpg")
            let resolvedSupport: Stock.Support = (info["stage"] as? String) == "printing"
                ? .paper : support
            let stock = Stock(id: id, name: name, support: resolvedSupport, type: type,
                              coverURL: FileManager.default.fileExists(atPath: cover.path) ? cover : nil,
                              monochrome: (info["channel_model"] as? String) == "bw",
                              targetPrint: info["target_print"] as? String)
            switch (resolvedSupport, type) {
            case (.film, .negative): films.append(stock)
            case (.film, .positive): slides.append(stock)
            case (.paper, _): papers.append(stock)
            }
        }

        // Sorted by display name, colour before black and white: the list is a menu, and a menu is read.
        let order: (Stock, Stock) -> Bool = { ($0.monochrome ? 1 : 0, $0.name) < ($1.monochrome ? 1 : 0, $1.name) }
        return StockCatalog(films: films.sorted(by: order),
                            papers: papers.sorted(by: order),
                            slides: slides.sorted(by: order),
                            grades: PaperGrade.load(resources: resources))
    }

    /// The bundle's catalogue, for code that has no view model (a recipe's wire delta).
    static let shared = StockCatalog.load(resources: SpektraEngine.defaultResources())

    // MARK: black and white (upstream `Model/Stock.swift`, the desktop's rules)

    let grades: [PaperGrade]

    func stock(_ id: String) -> Stock? { (films + papers + slides).first { $0.id == id } }
    func isMonochrome(_ id: String) -> Bool { stock(id)?.monochrome ?? false }

    /// Silver on silver, colour on colour. An unknown stock rules nothing out.
    func canPrint(film: String, on paper: String) -> Bool {
        guard let f = stock(film), let p = stock(paper) else { return true }
        return f.monochrome == p.monochrome
    }

    /// The paper a film is made for, else the first of its kind.
    func ownPaper(of film: String) -> String? {
        guard let f = stock(film) else { return nil }
        if let own = f.targetPrint, let p = stock(own), p.support == .paper, p.monochrome == f.monochrome { return own }
        return papers.first { $0.monochrome == f.monochrome }?.id
    }

    func grade(_ name: String) -> PaperGrade? { grades.first { $0.name == name } }

    /// The stocks to show when nothing is chosen yet.
    ///
    /// Portra 400 and Crystal Archive: the pair most people reach for first,
    /// and one that is a negative film and a paper, so the app can open and
    /// print a frame without the user having to choose anything.
    static let defaultFilm = "kodak_portra_400"
    static let defaultPaper = "fujifilm_crystal_archive_typeii"

    /// The paper whose preview LUT is paired with a given film, if any.
    ///
    /// The engine's `print_luts.json` records which film each preview table
    /// was baked against, and a mismatch is an approximation with unmeasured
    /// error. So when the user picks a film that has a paired paper, that
    /// paper is offered first.
    static func pairedPaper(forFilm film: String, in resources: URL) -> String? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("print_luts.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for (_, value) in json {
            guard let entry = value as? [String: Any],
                  let paired = entry["paired_film"] as? String,
                  paired == film else { continue }
            return (entry["paper"] as? String)
                ?? entry["print_stock"] as? String
                ?? paperForLUTKey(film: film, resources: resources)
        }
        return nil
    }

    /// The LUT index is keyed by paper name, so the pairing runs the other
    /// way: find the entry whose `paired_film` matches, and take its key.
    private static func paperForLUTKey(film: String, resources: URL) -> String? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("print_luts.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for (key, value) in json {
            guard let entry = value as? [String: Any],
                  let paired = entry["paired_film"] as? String,
                  paired == film else { continue }
            return key
        }
        return nil
    }
}

/// A Multigrade filter: the enlarger pack and exposure that print one contrast
/// grade (`resources_product/paper_grades.json`, fitted on the engine).
struct PaperGrade: Sendable, Hashable, Identifiable {
    let name: String
    let magenta: Double
    let yellow: Double
    let printExposure: Double
    var id: String { name }

    static let standard = "2"

    static func load(resources: URL) -> [PaperGrade] {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("paper_grades.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grades = json["grades"] as? [String: [String: Double]] else { return [] }
        let order = ["00", "0", "1", "2", "3", "4", "5"]
        return grades.compactMap { name, g in
            guard let m = g["m_filter_neutral"], let y = g["y_filter_neutral"], let e = g["print_exposure"] else { return nil }
            return PaperGrade(name: name, magenta: m, yellow: y, printExposure: e)
        }
        .sorted { (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99) }
    }
}
