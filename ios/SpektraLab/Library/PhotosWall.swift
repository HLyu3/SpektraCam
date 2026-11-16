//  PhotosWall.swift — the system Photos library as a wall, newest first, by album. Thumbnails load
//  as cells come on screen, so a library of tens of thousands scrolls like a small one; the wall
//  follows changes made in Photos while it is open. A photo with a SpektraLab look shows its
//  developed thumbnail and its film.

import Photos
import SwiftUI

/// An album to browse: all photos, a smart album (favourites, RAW…), or one of the person's own.
struct PhotoAlbum: Identifiable, Hashable {
    let id: String              // "" for all photos, else the collection's local identifier
    let title: String
    let symbol: String
}

@MainActor
final class PhotosFeed: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var assets: PHFetchResult<PHAsset>?
    @Published private(set) var denied = false
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published var album = PhotoAlbum(id: "", title: "全部照片", symbol: "photo.on.rectangle")
    let images = PHCachingImageManager()
    private var observing = false
    /// Told after Photos changed (the wall uses it to drop entries of deleted photos).
    var onChange: (@MainActor () -> Void)?

    func load() async {
        guard await PhotoAssets.authorize() else { denied = true; return }
        denied = false
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        albums = Self.listAlbums()
        refetch()
    }

    func choose(_ a: PhotoAlbum) { album = a; refetch() }

    private func refetch() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        if album.id.isEmpty {
            assets = PHAsset.fetchAssets(with: options)
        } else if let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject {
            assets = PHAsset.fetchAssets(in: c, options: options)
        } else {
            album = PhotoAlbum(id: "", title: "全部照片", symbol: "photo.on.rectangle")
            assets = PHAsset.fetchAssets(with: options)
        }
    }

    /// Favourites, RAW and the camera's own smart albums first, then the person's albums.
    private static func listAlbums() -> [PhotoAlbum] {
        var out = [PhotoAlbum(id: "", title: "全部照片", symbol: "photo.on.rectangle")]
        let smart: [(PHAssetCollectionSubtype, String, String)] = [
            (.smartAlbumFavorites, "个人收藏", "heart"), (.smartAlbumRAW, "RAW", "r.square"),
            (.smartAlbumSelfPortraits, "自拍", "person.crop.square"), (.smartAlbumScreenshots, "截屏", "camera.viewfinder"),
        ]
        for (subtype, title, symbol) in smart {
            if let c = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject {
                out.append(PhotoAlbum(id: c.localIdentifier, title: title, symbol: symbol))
            }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
            out.append(PhotoAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "相簿", symbol: "rectangle.stack"))
        }
        return out
    }

    nonisolated func photoLibraryDidChange(_ change: PHChange) {
        Task { @MainActor in
            self.onChange?()
            guard let assets, let details = change.changeDetails(for: assets) else { return }
            self.assets = details.fetchResultAfterChanges
        }
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
}

struct PhotosWall: View {
    @ObservedObject var model: ViewModel
    @ObservedObject var feed: PhotosFeed
    let selecting: Bool
    @Binding var selected: [String]
    /// Tiles a row: the library's pinch level.
    var columnCount = 3
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnCount >= 7 ? 1 : 4, alignment: .top), count: columnCount)
    }

    var body: some View {
        Group {
            if feed.denied {
                VStack(spacing: 10) {
                    Text("没有相册权限").font(.headline).foregroundStyle(Color.labCream)
                    Text("在“设置 > Spektra Cam > 照片”里选“所有照片”，或把来源改回 Spektra Cam 图库。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else if let assets = feed.assets {
                // One lookup per draw, not one scan of the library per cell.
                let linked = Dictionary(model.library.compactMap { p in p.assetID.map { ($0, p) } },
                                        uniquingKeysWith: { a, _ in a })
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(0..<assets.count, id: \.self) { i in
                        let asset = assets.object(at: i)
                        let id = asset.localIdentifier
                        AssetCell(asset: asset, linked: linked[id], model: model, images: feed.images,
                                  selecting: selecting, isSelected: selected.contains(id))
                            .onTapGesture {
                                if selecting {
                                    if let k = selected.firstIndex(of: id) { selected.remove(at: k) } else { selected.append(id) }
                                } else {
                                    Task { @MainActor in await model.openAsset(id) }
                                }
                            }
                    }
                }
            } else {
                ProgressView().tint(Color.labCream).frame(maxWidth: .infinity).padding(.vertical, 60)
            }
        }
        .task {
            feed.onChange = { model.pruneDeletedAssets() }
            await feed.load()
            model.pruneDeletedAssets()
        }
    }
}

/// The album menu, for the wall's section header.
struct PhotoAlbumMenu: View {
    @ObservedObject var feed: PhotosFeed
    var body: some View {
        Menu {
            Picker("相簿", selection: Binding(get: { feed.album }, set: { feed.choose($0) })) {
                ForEach(feed.albums) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: feed.album.symbol)
                Text(feed.album.title).lineLimit(1)
                if let n = feed.assets?.count { Text("\(n)").foregroundStyle(Color.labCream.opacity(0.4)) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.labCream.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.white.opacity(0.06), in: Capsule())
        }
        .accessibilityLabel("相簿：\(feed.album.title)")
    }
}

private struct AssetCell: View {
    let asset: PHAsset
    let linked: LibraryPhoto?
    @ObservedObject var model: ViewModel
    let images: PHCachingImageManager
    let selecting: Bool
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.labPanel
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                // A photo with a look shows how it develops; the rest show the original.
                if let shown = linked?.thumbnail ?? image {
                    Image(uiImage: shown).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let linked {
                    HStack(spacing: 4) {
                        if linked.isEdited { Circle().fill(Color.labRed).frame(width: 4, height: 4) }
                        Text(model.shortFilmName(for: linked.recipe.filmStock))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay { if isSelected { Color.labRed.opacity(0.12) } }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    ZStack {
                        Circle().fill(isSelected ? Color.labRed : Color.black.opacity(0.28))
                        Circle().strokeBorder(Color.white.opacity(isSelected ? 0 : 0.72), lineWidth: 1.5)
                        if isSelected {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.labRed, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                guard linked == nil else { return }
                image = await PhotoAssets.thumbnail(asset, side: 300, manager: images)
            }
            .accessibilityLabel(linked.map { "已冲洗，\(model.filmName(for: $0.recipe.filmStock))" } ?? "相册照片")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
