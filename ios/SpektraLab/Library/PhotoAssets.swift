//  PhotoAssets.swift — reading the system Photos library in place: the original file of an asset
//  (its RAW when it has one), and thumbnails. Nothing here writes to Photos.

import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoAssets {
    /// Read access to the whole library (or the photos the person picked under limited access).
    static func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static func asset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// The file a photo was taken as: the RAW of a RAW + JPEG pair, else the original photo
    /// (never Photos' edited rendition).
    static func originalResource(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let isRAW: (PHAssetResource) -> Bool = { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false }
        return resources.first { $0.type == .alternatePhoto && isRAW($0) }
            ?? resources.first { $0.type == .photo }
            ?? resources.first
    }

    /// The original's bytes, downloaded from iCloud if they are not on the phone.
    static func originalData(_ asset: PHAsset) async throws -> (data: Data, type: String?) {
        guard let resource = originalResource(asset) else {
            throw DecodeError.unreadable(String(localized: "这张照片在相册里没有原图"))
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        var data = Data()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(for: resource, options: options,
                                                         dataReceivedHandler: { data.append($0) },
                                                         completionHandler: { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
        return (data, resource.uniformTypeIdentifier)
    }

    /// Save a file into Photos as it is (a DNG stays a DNG). Returns the new asset's identifier.
    static func save(_ data: Data, uti: String) async throws -> String {
        final class Box: @unchecked Sendable { var id: String? }
        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = uti
            request.addResource(with: .photo, data: data, options: options)
            box.id = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = box.id else { throw DecodeError.unreadable(String(localized: "照片没能存进相册")) }
        return id
    }

    static func thumbnail(_ asset: PHAsset, side: CGFloat, manager: PHImageManager = .default()) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { done in
            var finished = false
            manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                 contentMode: .aspectFill, options: options) { image, info in
                // Opportunistic delivery calls back twice: a quick degraded image, then the real one.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !finished, !degraded || image == nil else { return }
                finished = true
                done.resume(returning: image)
            }
        }
    }
}
