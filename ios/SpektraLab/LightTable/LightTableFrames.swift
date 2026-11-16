//  LightTableFrames.swift — this app's photos as the light table reads them: their size in millimetres
//  and the picture drawn. Replaces upstream's `LightTableFrames` / `LightTableSizing` / `LightTableFullRead`,
//  which read the Mac library's own frame type; the rest of `LightTable/` is upstream's, trimmed.
//
//  The picture is the photo's developed thumbnail on disk (`<id>-thumb.jpg`, ≤ 900 px), the same one the
//  wall shows. shortcut: 900 px goes soft past ~6× zoom on a 36 mm frame; keep a larger develop if that matters.

import CoreGraphics
import Foundation

/// A library photo as the table needs it. Equatable: a changed look or thumbnail is a new value, and
/// the controller reads its size and picture again (`LightTableController.sync`).
struct LibraryFrame: Equatable, Sendable {
    var id: UUID
    /// Its size on the table, mm, as its picture lies unturned.
    var sizeMM: CGSize
    var thumbnail: URL
    /// Changes when the thumbnail is written again, so the texture is read again.
    var stamp: Date
    var caption: String
}

/// Where a film's picture is read from. `key` names the picture exactly.
enum LightTableSource: Equatable, Sendable {
    case picture(URL)
    /// Upstream's full-size render; never made here.
    case full(LightTableFullRef)
    case none

    var key: String {
        switch self {
        case .picture(let u): "p|\(u.path)"
        case .full(let r): "F|\(r.key)"
        case .none: "-"
        }
    }
}

struct LightTableFullRef: Equatable, Sendable { var key: String }

enum LightTableFullRead {
    static func image(_ ref: LightTableFullRef, edge: Int) -> CGImage? { nil }
}

enum LightTableSizing {
    /// The most a film is read at (upstream's 6 × 17 strip on A6 at 5,000 px).
    static let sourceCeiling = 8224
}

@MainActor
enum LightTableFrames {
    static func size(of frame: LibraryFrame, bodySeed: Int) -> CGSize { frame.sizeMM }

    static func source(of frame: LibraryFrame, bodySeed: Int) -> LightTableSource {
        FileManager.default.fileExists(atPath: frame.thumbnail.path) ? .picture(frame.thumbnail) : .none
    }

    /// The thumbnail is all there is: never ask for more.
    static func keptEdge(of frame: LibraryFrame) -> Int? { Int(LibraryThumbnail.maxPixel) }

    static func caption(of frame: LibraryFrame) -> String { frame.caption }

    /// A photo's size on the table. With the film edge: the strip's width across its short side
    /// (35 mm film, 61 mm for 120). Without: the uncut frame's long edge is `filmFormatMM` (35 mm
    /// film by default), and a crop is a smaller piece of that negative.
    static func sizeMM(of photo: LibraryPhoto) -> CGSize {
        let aspect = max(photo.aspect, 0.01)               // the thumbnail as shown, crop and edge included
        let r = photo.recipe
        if r.filmBorderEnabled {
            let gate = FilmGateCatalog.resolve(selection: r.overscanFormat, imageAspect: photo.sourceAspect)
            let across = gate.id.hasPrefix("120") ? 61.0 : 35.0
            return aspect >= 1 ? CGSize(width: across * aspect, height: across) : CGSize(width: across, height: across / aspect)
        }
        let format = r.filmFormatMM ?? 36
        let w = max(photo.sourceAspect, 0.01), h = 1.0       // the uncut source, its height 1
        let c = photo.crop ?? FrameCrop()
        let long = format * max(c.width * w, c.height * h) / max(w, h)
        return aspect >= 1 ? CGSize(width: long, height: long / aspect) : CGSize(width: long * aspect, height: long)
    }
}
