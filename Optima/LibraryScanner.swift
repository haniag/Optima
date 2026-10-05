//
//  LibraryScanner.swift
//  Optima
//

import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Finds the photos in the library that are worth compressing.
nonisolated enum LibraryScanner {
    /// Only photos larger than this are included (1.5 MB, as Finder counts it).
    static let minimumFileSize: Int64 = 1_500_000

    /// Photo kinds that are skipped, because replacing them would lose something
    /// (the motion of a Live Photo, the depth of a Portrait) or isn't worth it.
    private static let excludedSubtypes: PHAssetMediaSubtype = [
        .photoPanorama, .photoLive, .photoDepthEffect, .photoScreenshot,
    ]

    /// `@unchecked Sendable` so scans can run in the background: PHAsset is a
    /// read-only snapshot, safe to pass between threads.
    struct Candidate: Identifiable, @unchecked Sendable {
        let asset: PHAsset
        let fileName: String
        let fileSize: Int64
        var id: String { asset.localIdentifier }
    }

    /// Every JPEG photo, or HEIC photo straight from the camera, over 1.5 MB, newest first,
    /// except panoramas, Live Photos, Portraits, screenshots, selfies, bursts and edited photos.
    /// Videos (including slo-mo) and HEICs that were already compressed are never included,
    /// and no HEICs at all when "Re-compress existing HEICs" is off in Settings.
    /// If the scan is cancelled, returns what it found up to that point.
    @concurrent
    static func findCandidates() async -> [Candidate] {
        let selfieIDs = assetIDs(inSmartAlbum: .smartAlbumSelfPortraits)
        let includeHEIC = OptimaSettings.recompressHEIC

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let photos = PHAsset.fetchAssets(with: .image, options: options)

        var candidates: [Candidate] = []
        photos.enumerateObjects { asset, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard asset.mediaSubtypes.isDisjoint(with: excludedSubtypes),
                  asset.burstIdentifier == nil,
                  !selfieIDs.contains(asset.localIdentifier)
            else { return }
            let resources = PHAssetResource.assetResources(for: asset)
            // Edited photos carry their edited version as an extra file; compressing would
            // bake the edits in and lose "Revert to Original", so they're skipped.
            guard !resources.contains(where: { $0.type == .fullSizePhoto || $0.type == .adjustmentData }),
                  let original = resources.first(where: { $0.type == .photo }),
                  let type = UTType(original.uniformTypeIdentifier),
                  type.conforms(to: .jpeg) || (includeHEIC && isHEIC(type) && !wasCompressedBefore(asset)),
                  let size = fileSize(of: original), size > minimumFileSize
            else { return }
            candidates.append(Candidate(asset: asset, fileName: original.originalFilename, fileSize: size))
        }
        return candidates
    }

    /// The photo's original file, downloaded from iCloud first if it isn't on this device.
    /// Throws Photos' own error (or `OriginalUnavailable`) when the file can't be loaded.
    static func originalData(of asset: PHAsset) async throws -> Data {
        let options = PHImageRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: OriginalUnavailable(info: info.map { String(describing: $0) } ?? "none"))
                }
            }
        }
    }

    /// Photos returned no file and no error; `info` is what it did say, for the log.
    struct OriginalUnavailable: LocalizedError {
        let info: String
        var errorDescription: String? { "Photos returned no original file (info: \(info))." }
    }

    /// HEIC and HEIF are sibling types (neither "is a" the other), so check both.
    static func isHEIC(_ type: UTType) -> Bool {
        type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    /// ⚠️ PRIVATE API — reads the photo's EXIF without downloading it.
    /// True for HEICs that were compressed before: Optima's own (they carry its marker as
    /// User Comment; photos with any other comment are left alone too) and ones converted
    /// from JPEG, which keep JPEG-only EXIF tags the camera never writes into a HEIC.
    /// Also true if macOS stops providing the EXIF, so nothing is ever compressed twice.
    private static func wasCompressedBefore(_ asset: PHAsset) -> Bool {
        guard asset.responds(to: NSSelectorFromString("originalImageProperties")),
              let properties = asset.value(forKey: "originalImageProperties") as? [String: Any]
        else { return true }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        return exif[kCGImagePropertyExifUserComment as String] != nil
            || exif[kCGImagePropertyExifComponentsConfiguration as String] != nil
            || exif[kCGImagePropertyExifFlashPixVersion as String] != nil
    }

    private static func assetIDs(inSmartAlbum subtype: PHAssetCollectionSubtype) -> Set<String> {
        var ids: Set<String> = []
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            .enumerateObjects { album, _, _ in
                PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                    ids.insert(asset.localIdentifier)
                }
            }
        return ids
    }

    /// ⚠️ PRIVATE API — PhotoKit has no public way to read a photo's file size
    /// without downloading it. Returns nil if iOS/macOS stops providing it.
    static func fileSize(of resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }
}
