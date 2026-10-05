//
//  PhotoLibrarySaver.swift
//  Optima
//

import Foundation
import Photos

/// Replaces photos and videos in the user's library with their compressed versions.
nonisolated enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case notAuthorized
        case originalNotFound

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "Optima needs access to your photos to replace them. You can allow it in Settings › Apps › Optima › Photos."
            case .originalNotFound:
                "Some original photos couldn't be found. Make sure Optima has Full Access in Settings › Apps › Optima › Photos."
            }
        }
    }

    /// Adds each compressed photo to the library with its original's date, location,
    /// favorite status and albums, then deletes the original (it goes to Recently Deleted).
    /// It all happens in one step: if the user declines the delete prompt, nothing changes.
    ///
    /// Returns false if the photos were replaced but their "date added" couldn't be kept,
    /// so they'll show up as recently added.
    @discardableResult
    static func replaceOriginals(with photos: [CompressedPhoto]) async throws -> Bool {
        try await replace(photos.map { photo in
            // Adding the raw file (rather than a UIImage) keeps its EXIF metadata intact.
            (photo.assetIdentifier, { $0.addResource(with: .photo, data: photo.data, options: nil) })
        })
    }

    /// The same as for photos, for videos. Photos moves each new video file into the library;
    /// files left behind (e.g. if the user declines) are for the caller to delete.
    @discardableResult
    static func replaceOriginals(with videos: [CompressedVideo]) async throws -> Bool {
        let options = PHAssetResourceCreationOptions()
        options.shouldMoveFile = true
        return try await replace(videos.map { video in
            (video.assetIdentifier, { $0.addResource(with: .video, fileURL: video.fileURL, options: options) })
        })
    }

    /// Replaces each original (by its ID) with a new item, whose file `addFile` adds.
    private static func replace(_ items: [(originalID: String?, addFile: (PHAssetCreationRequest) -> Void)]) async throws -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw SaveError.notAuthorized }

        // Look up the original for each compressed item.
        let identifiers = items.compactMap(\.originalID)
        var originalsByID: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            .enumerateObjects { asset, _, _ in originalsByID[asset.localIdentifier] = asset }

        let replacements = try items.map { item in
            guard let id = item.originalID, let original = originalsByID[id] else {
                throw SaveError.originalNotFound
            }
            return (addFile: item.addFile, original: original, albums: albums(containing: original))
        }

        // The new items' IDs, paired with the "date added" of the original each one replaces.
        var dateAddedByNewPhotoID: [String: Date] = [:]

        try await PHPhotoLibrary.shared().performChanges {
            for (addFile, original, albums) in replacements {
                let request = PHAssetCreationRequest.forAsset()
                addFile(request)
                // Copy what Photos shows for the original, so the new item sits in the same spot.
                request.creationDate = original.creationDate
                request.location = original.location
                request.isFavorite = original.isFavorite

                if let newPhoto = request.placeholderForCreatedAsset {
                    for album in albums {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([newPhoto] as NSArray)
                    }
                    dateAddedByNewPhotoID[newPhoto.localIdentifier] = PrivatePhotosAPI.dateAdded(of: original)
                }
            }
            PHAssetChangeRequest.deleteAssets(replacements.map(\.original) as NSArray)
        }

        // Done as a separate second step, so if iOS refuses it the replacement above still stands.
        return await restoreDateAdded(dateAddedByNewPhotoID)
    }

    /// Gives each new photo its original's "date added", then reads it back to confirm
    /// iOS actually kept it. Returns false if any photo didn't get its date.
    private static func restoreDateAdded(_ dates: [String: Date]) async -> Bool {
        guard !dates.isEmpty, PrivatePhotosAPI.canSetDateAdded else { return false }

        let newPhotos = PHAsset.fetchAssets(withLocalIdentifiers: Array(dates.keys), options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                newPhotos.enumerateObjects { asset, _, _ in
                    if let date = dates[asset.localIdentifier] {
                        PrivatePhotosAPI.setDateAdded(date, on: PHAssetChangeRequest(for: asset))
                    }
                }
            }
        } catch {
            return false
        }

        var allKept = true
        PHAsset.fetchAssets(withLocalIdentifiers: Array(dates.keys), options: nil).enumerateObjects { asset, _, _ in
            guard let wanted = dates[asset.localIdentifier],
                  let actual = PrivatePhotosAPI.dateAdded(of: asset),
                  abs(actual.timeIntervalSince(wanted)) < 1
            else { allKept = false; return }
        }
        return allKept
    }

    /// The user's own albums that contain this photo (and that we're allowed to add to).
    private static func albums(containing asset: PHAsset) -> [PHAssetCollection] {
        var albums: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            .enumerateObjects { album, _, _ in
                if album.canPerform(.addContent) { albums.append(album) }
            }
        return albums
    }
}

/// ⚠️ PRIVATE API — undocumented Photos methods Apple doesn't allow in App Store apps.
/// Fine for a personal app, but iOS updates may remove or block them at any time,
/// so every call checks the method still exists (calling a missing one would crash).
private nonisolated enum PrivatePhotosAPI {
    private static let getter = NSSelectorFromString("addedDate")
    private static let setter = NSSelectorFromString("setAddedDate:")

    static var canSetDateAdded: Bool {
        PHAssetChangeRequest.instancesRespond(to: setter)
    }

    /// When the photo was added to the library (not when it was taken).
    static func dateAdded(of asset: PHAsset) -> Date? {
        guard asset.responds(to: getter) else { return nil }
        return asset.value(forKey: "addedDate") as? Date
    }

    static func setDateAdded(_ date: Date, on request: PHAssetChangeRequest) {
        guard request.responds(to: setter) else { return }
        request.setValue(date, forKey: "addedDate")
    }
}
