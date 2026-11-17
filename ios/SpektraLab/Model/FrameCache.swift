//  FrameCache.swift — a photo's decoded preview frame kept on disk (half floats, the size the editor decodes at), so
//  opening it again skips the RAW decode: 0.85 s for a 12 MP ProRAW on a 17 Pro Max, against a ~30 ms read. Made by
//  the background develop for a new shot and by the first open of any photo. The frame is the uncropped decode
//  (crop, turns and white balance are applied after), so it serves every look; a different 预览尺寸 is a miss.

import Accelerate
import Foundation

enum FrameCache {
    private static let magic: UInt32 = 0x31465053      // "SPF1"

    static func read(_ url: URL, edge: Int) -> DecodedFrame? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 16 else { return nil }
        DevelopCache.touch(url)
        let head = data.withUnsafeBytes { raw in (0..<4).map { raw.load(fromByteOffset: $0 * 4, as: UInt32.self) } }
        let (w, h) = (Int(head[1]), Int(head[2]))
        guard head[0] == magic, Int(head[3]) == edge, w > 0, h > 0, data.count == 16 + w * h * 3 * 2 else { return nil }
        var floats = [Float](repeating: 0, count: w * h * 3)
        // vImage, not a Swift loop: the loop was ~0.5 s in a debug build, as slow as the decode it replaces.
        data.withUnsafeBytes { raw in
            floats.withUnsafeMutableBufferPointer { dst in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress!.advanced(by: 16)),
                                        height: 1, width: vImagePixelCount(dst.count), rowBytes: dst.count * 2)
                var out = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(dst.count), rowBytes: dst.count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&src, &out, vImage_Flags(kvImageNoFlags))
            }
        }
        return DecodedFrame(pixels: FloatRGBPixels(floats), width: w, height: h)
    }

    static func write(_ frame: DecodedFrame, edge: Int, to url: URL) {
        let n = frame.width * frame.height * 3
        var data = Data(count: 16 + n * 2)
        data.withUnsafeMutableBytes { raw in
            let head = [magic, UInt32(frame.width), UInt32(frame.height), UInt32(edge)]
            for (i, v) in head.enumerated() { raw.storeBytes(of: v, toByteOffset: i * 4, as: UInt32.self) }
            frame.pixels.withUnsafeBufferPointer { src in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                         width: vImagePixelCount(n), rowBytes: n * 4)
                var to = vImage_Buffer(data: raw.baseAddress!.advanced(by: 16), height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        try? data.write(to: url, options: .atomic)
    }
}


/// The develops kept to make viewing and editing fast — `<id>-preview.f16` (the editor's decoded frame) and
/// `<id>-large.jpg` (the 3072 px develop) — and their upkeep: used ones are touched, ones unused for
/// `keepDays` are deleted at launch, and Settings shows their size with a 清除 button. All of them can be made again;
/// thumbnails and originals are never touched here.
enum DevelopCache {
    static let keepDaysKey = "SpektraLab.developCacheDays"
    /// Days a cache file may go unused; 0 = keep. 14 by default.
    static var keepDays: Int { UserDefaults.standard.object(forKey: keepDaysKey) as? Int ?? 14 }

    static func isCache(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix("-preview.f16") || url.lastPathComponent.hasSuffix("-large.jpg")
    }

    /// Marks a cache file used now (its modification date: iOS keeps no access dates).
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func files(in root: URL) -> [(url: URL, bytes: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        return all.filter(isCache).map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
        }
    }

    static func bytes(in root: URL) -> Int64 { files(in: root).reduce(0) { $0 + $1.bytes } }

    /// Deletes cache files unused for `days` (all of them with nil). Returns the bytes freed.
    @discardableResult
    static func prune(in root: URL, olderThanDays days: Int?) -> Int64 {
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        var freed: Int64 = 0
        for f in files(in: root) where cutoff.map({ f.used < $0 }) ?? true {
            if (try? FileManager.default.removeItem(at: f.url)) != nil { freed += f.bytes }
        }
        return freed
    }
}
