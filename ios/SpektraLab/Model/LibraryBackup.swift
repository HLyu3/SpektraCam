//  LibraryBackup.swift — 自动备份 / 从备份恢复.
//
//  The library folder (`SpektraLabLibrary`: originals, thumbnails, `library.json`, `recipes.json`, `lighttable.json`,
//  `watermarks/`) is kept MIRRORED into a folder the owner picks once — iCloud Drive is the point: the free Apple ID
//  cannot have an iCloud container of its own, but a folder the document picker hands over (a security-scoped bookmark)
//  can be written to for ever. The mirror is incremental: only files new or changed since the last run are copied
//  (the record is `indexKey`, name → size|mtime), files gone from the library are deleted from it, the manifest goes
//  last so a run cut short never names a file the backup lacks. The develop cache stays out (it is made again); the
//  app's own settings (every `SpektraLab.` key of UserDefaults) go in as `settings.plist`. It runs when the app goes
//  to the background (with the time iOS grants) and at launch when the last run is over six hours old.
//
//  A restore is two-step so nothing running writes over it: the backup is copied and checked now into
//  `SpektraLabLibrary-restore`, and the next launch, before anything is read, puts it in place of the library
//  (`applyPendingRestore`). Photos only LINKED to the system library (`assetID`) come back as links: on another phone
//  they find nothing and are dropped.

import Foundation
import UIKit

enum LibraryBackup {
    enum Failure: LocalizedError {
        case folder, notABackup, space(Int)
        var errorDescription: String? {
            switch self {
            case .folder: String(localized: "打不开备份文件夹，请重新选择")
            case .notABackup: String(localized: "这个文件夹里没有 Spektra Cam 的底片库备份")
            case .space(let mb): String(localized: "手机空间不够：还需要大约 \(mb) MB")
            }
        }
    }

    /// The folder made inside the one picked.
    static let folderName = "Spektra Cam Library"
    private static let settingsName = "settings.plist"
    private static let pendingKey = "SpektraLab.pendingRestore"
    private static let bookmarkKey = "SpektraLab.backupFolder"
    private static let indexKey = "SpektraLab.backupIndex"
    static let lastKey = "SpektraLab.backupLast"
    /// Files written last: what names the rest.
    private static let manifests: Set<String> = ["library.json", "recipes.json", "lighttable.json", settingsName]

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }
    static var libraryURL: URL { support.appendingPathComponent("SpektraLabLibrary", isDirectory: true) }
    private static var restoreURL: URL { support.appendingPathComponent("SpektraLabLibrary-restore", isDirectory: true) }

    /// Whether a file goes into a backup: the develop cache does not.
    static func keeps(_ name: String) -> Bool { !DevelopCache.isCache(URL(fileURLWithPath: name)) && name != settingsName }

    /// Bytes the backup holds.
    static func size() -> Int64 { files().reduce(0) { $0 + $1.size } }

    private static func freeBytes() -> Int64 {
        (try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    /// The library's files to back up: path relative to the library, size, and the key that says it changed.
    private static func files() -> [(path: String, size: Int64, key: String)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: libraryURL, includingPropertiesForKeys: keys) else { return [] }
        let root = libraryURL.standardizedFileURL.path + "/"
        var out: [(String, Int64, String)] = []
        for case let url as URL in e where keeps(url.lastPathComponent) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.count))
            let size = Int64(v.fileSize ?? 0)
            out.append((path, size, "\(size)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"))
        }
        return out
    }

    // MARK: the folder

    static var hasFolder: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// The picked folder's name, for Settings.
    static var folderTitle: String? {
        guard let url = resolvedFolder() else { return nil }
        return url.lastPathComponent
    }

    static var last: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }

    /// Keeps the folder the document picker handed over (its access lasts through the bookmark).
    static func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: indexKey)       // a new place: everything is copied again
        UserDefaults.standard.removeObject(forKey: lastKey)
    }

    static func forgetFolder() {
        for k in [bookmarkKey, indexKey, lastKey] { UserDefaults.standard.removeObject(forKey: k) }
    }

    private static func resolvedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    // MARK: backup

    /// One run of the mirror; returns the files copied. Off the main actor. `shouldStop` is asked between files
    /// (the background time running out): what is copied stays recorded, the next run goes on from there.
    static func mirror(shouldStop: @Sendable () -> Bool = { false }) throws -> Int {
        guard let picked = resolvedFolder() else { throw Failure.folder }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let dest = picked.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        // The settings, beside the files, written fresh each run.
        let settings = UserDefaults.standard.dictionaryRepresentation().filter {
            $0.key.hasPrefix("SpektraLab.") && ![pendingKey, bookmarkKey, indexKey, lastKey].contains($0.key)
        }
        let settingsData = try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)

        var index = UserDefaults.standard.dictionary(forKey: indexKey) as? [String: String] ?? [:]
        let all = files()
        let present = Set(all.map(\.path))
        let todo = all.filter { index[$0.path] != $0.key }
            .sorted { (manifests.contains($0.path) ? 1 : 0, $0.path) < (manifests.contains($1.path) ? 1 : 0, $1.path) }
        let coordinator = NSFileCoordinator()
        var copied = 0
        for f in todo {
            if shouldStop() { break }
            let from = libraryURL.appendingPathComponent(f.path), to = dest.appendingPathComponent(f.path)
            var failure: Error?
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: to, options: .forReplacing, error: &coordError) { url in
                do {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                    try fm.copyItem(at: from, to: url)
                } catch { failure = error }
            }
            if let e = failure ?? coordError { throw e }
            index[f.path] = f.key
            copied += 1
            if copied % 20 == 0 { UserDefaults.standard.set(index, forKey: indexKey) }
        }
        UserDefaults.standard.set(index, forKey: indexKey)
        guard !shouldStop() else { return copied }
        // Gone from the library: gone from the backup.
        for path in index.keys where !present.contains(path) {
            try? fm.removeItem(at: dest.appendingPathComponent(path))
            index[path] = nil
        }
        UserDefaults.standard.set(index, forKey: indexKey)
        try settingsData.write(to: dest.appendingPathComponent(settingsName), options: .atomic)
        UserDefaults.standard.set(Date(), forKey: lastKey)
        return copied
    }

    // MARK: restore

    /// Copies a backup folder (the one picked, or `Spektra Cam Library` inside it) beside the library and checks it is
    /// one; the next launch puts it in place.
    static func prepareRestore(from picked: URL) throws {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let inner = picked.appendingPathComponent(folderName, isDirectory: true)
        let source = fm.fileExists(atPath: inner.appendingPathComponent("library.json").path) ? inner : picked
        // Reading through a coordinator downloads what iCloud has evicted from the phone.
        var copyError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordError) { url in
            do {
                guard fm.fileExists(atPath: url.appendingPathComponent("library.json").path) else { throw Failure.notABackup }
                let need = (fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
                    .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                let free = freeBytes()
                if free < need + 200 * 1_048_576 { throw Failure.space(Int((need + 200 * 1_048_576 - free) >> 20)) }
                try? fm.removeItem(at: restoreURL)
                try fm.copyItem(at: url, to: restoreURL)
            } catch { copyError = error }
        }
        if let e = copyError ?? coordError { try? fm.removeItem(at: restoreURL); throw e }
        let manifest = restoreURL.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: manifest), (try? JSONSerialization.jsonObject(with: data)) is [Any] else {
            try? fm.removeItem(at: restoreURL)
            throw Failure.notABackup
        }
        UserDefaults.standard.set(true, forKey: pendingKey)
    }

    /// At launch, before the library is read: a prepared restore takes the library's place, its settings with it.
    static func applyPendingRestore() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: pendingKey) else { return }
        defaults.removeObject(forKey: pendingKey)
        let fm = FileManager.default
        guard fm.fileExists(atPath: restoreURL.appendingPathComponent("library.json").path) else { return }
        let old = support.appendingPathComponent("SpektraLabLibrary-before-restore", isDirectory: true)
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: libraryURL.path) {
            guard (try? fm.moveItem(at: libraryURL, to: old)) != nil else { return }
        }
        guard (try? fm.moveItem(at: restoreURL, to: libraryURL)) != nil else {
            try? fm.moveItem(at: old, to: libraryURL)          // put the old one back
            return
        }
        let settingsURL = libraryURL.appendingPathComponent(settingsName)
        if let data = try? Data(contentsOf: settingsURL),
           let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (k, v) in settings where k.hasPrefix("SpektraLab.") { defaults.set(v, forKey: k) }
        }
        try? fm.removeItem(at: settingsURL)
        try? fm.removeItem(at: old)
        defaults.removeObject(forKey: indexKey)       // the library's files are new: the next run checks them all
        NSLog("SpektraLab backup: library restored")
    }
}

/// When the mirror runs: going to the background (inside the time iOS grants), and at launch when it is stale.
@MainActor
final class AutoBackup: ObservableObject {
    static let shared = AutoBackup()
    @Published private(set) var running = false
    @Published private(set) var lastError: String?

    /// `force`: now, whatever the last run (立即备份).
    func run(force: Bool = false, background: Bool = false) {
        guard LibraryBackup.hasFolder, !running else { return }
        if !force, let last = LibraryBackup.last, Date().timeIntervalSince(last) < (background ? 60 : 6 * 3600) { return }
        running = true
        let stop = StopFlag()
        let task = UIApplication.shared.beginBackgroundTask(withName: "backup") { stop.set() }
        Task.detached(priority: background ? .utility : .background) {
            let result = Result { try LibraryBackup.mirror(shouldStop: { stop.isSet }) }
            await MainActor.run {
                self.running = false
                switch result {
                case .success(let n): self.lastError = nil; NSLog("SpektraLab backup: %d files copied", n)
                case .failure(let e): self.lastError = e.localizedDescription; NSLog("SpektraLab backup: FAILED %@", e.localizedDescription)
                }
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
