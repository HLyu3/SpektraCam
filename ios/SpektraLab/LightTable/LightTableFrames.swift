//  LightTableFrames.swift — this app's photos as the light table reads them: their size in millimetres
//  and the picture drawn. Replaces upstream's `LightTableFrames` / `LightTableSizing` / `LightTableFullRead`,
//  which read the Mac library's own frame type; the rest of `LightTable/` is upstream's, trimmed.
//
//  The picture is the photo's developed thumbnail on disk (`<id>-thumb.jpg`, ≤ 900 px), the same one the
//  wall shows. shortcut: 900 px goes soft past ~6× zoom on a 36 mm frame; keep a larger develop if that matters.

import CoreGraphics
import Foundation
import ImageIO

/// A library photo as the table needs it. Equatable: a changed look or thumbnail is a new value, and
/// the controller reads its size and picture again (`LightTableController.sync`).
struct LibraryFrame: Equatable, Sendable {
    var id: UUID
    /// Its size on the table, mm, as its picture lies unturned.
    var sizeMM: CGSize
    var thumbnail: URL
    /// A 2048 px develop kept for the table and the slide show (`<id>-large.jpg`), made when a film is shown larger
    /// than its thumbnail; stale (and remade) once the thumbnail is newer, i.e. the look changed.
    var large: URL
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

/// This app's "full render": the 2048 px develop on disk. The ref's key is "path|stamp", so a new develop is a new key.
enum LightTableFullRead {
    static func image(_ ref: LightTableFullRef, edge: Int) -> CGImage? {
        let path = String(ref.key.split(separator: "|", maxSplits: 1).first ?? "")
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: edge]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// The frame's large develop, if there is one at least as new as its thumbnail.
    static func ref(_ frame: LibraryFrame) -> LightTableFullRef? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let large = (try? frame.large.resourceValues(forKeys: keys))?.contentModificationDate,
              large >= frame.stamp else { return nil }
        return LightTableFullRef(key: frame.large.path + "|" + String(large.timeIntervalSince1970))
    }
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

    /// The thumbnail's edge — or none once the large develop is made, so the table reads that (at any size, the
    /// loupe's included) instead of the 900 px thumbnail (`LightTableSteps.choose`).
    static func keptEdge(of frame: LibraryFrame) -> Int? {
        LightTableFullRead.ref(frame) == nil ? Int(LibraryThumbnail.maxPixel) : nil
    }

    static func caption(of frame: LibraryFrame) -> String { frame.caption }

    /// A photo's size on the table. With the film edge: the strip's width across its short side
    /// (35 mm film, 61 mm for 120). Without: the uncut frame's long edge is `filmFormatMM` (35 mm
    /// film by default), and a crop is a smaller piece of that negative.
    static func sizeMM(of photo: LibraryPhoto, print: Bool = false) -> CGSize {
        let aspect = max(photo.aspect, 0.01)               // the thumbnail as shown, crop and edge included
        // Print size (chosen in ⋯): a 5-inch print, 127 mm on its long side, whatever the negative.
        if print { return aspect >= 1 ? CGSize(width: 127, height: 127 / aspect) : CGSize(width: 127 * aspect, height: 127) }
        let r = photo.recipe
        if r.filmBorderEnabled {
            let gate = FilmGateCatalog.resolve(selection: r.overscanFormat, imageAspect: photo.sourceAspect)
            let across = gate.filmWidthMM          // 35 mm, 61 for 120, ~8 for Super 8, ~65 for 65 mm
            return aspect >= 1 ? CGSize(width: across * aspect, height: across) : CGSize(width: across, height: across / aspect)
        }
        let format = r.filmFormatMM ?? 36
        let w = max(photo.sourceAspect, 0.01), h = 1.0       // the uncut source, its height 1
        let c = photo.crop ?? FrameCrop()
        let long = format * max(c.width * w, c.height * h) / max(w, h)
        return aspect >= 1 ? CGSize(width: long, height: long / aspect) : CGSize(width: long * aspect, height: long)
    }
}
