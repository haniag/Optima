//
//  VideoLibraryScanner.swift
//  Optima
//

import AVFoundation
import Foundation
import Photos

/// Finds the videos in the library that are worth compressing.
nonisolated enum VideoLibraryScanner {
    /// Videos with a shorter side below this are never compressed.
    static let minimumShortSide = 720

    /// `@unchecked Sendable` so scans can run in the background: PHAsset is a
    /// read-only snapshot, safe to pass between threads.
    struct Candidate: Identifiable, @unchecked Sendable {
        let asset: PHAsset
        let resource: PHAssetResource
        let fileSize: Int64
        /// Bits per second of the picture alone (without sound).
        let videoBitRate: Float
        /// Roughly how many bytes compressing will save: the picture's bitrate drops to the one
        /// picked in Settings.
        let estimatedSavings: Int64
        var id: String { asset.localIdentifier }
        var fileName: String { resource.originalFilename }
    }

    /// Every H.264 video that's 720p or larger, and every HEVC video larger than the size picked
    /// in Settings (so it gets scaled down), whose picture is over the bitrate picked in Settings,
    /// newest first. Skipped: videos Optima already
    /// compressed (they carry its marker), anything below 720p, HDR (it would lose its HDR look),
    /// slo-mo, time-lapse, Cinematic, screen recordings, edited videos, and videos whose original
    /// isn't on this device. If the scan is cancelled, returns what it found up to that point.
    @concurrent
    static func findCandidates() async -> [Candidate] {
        let targetShortSide = OptimaSettings.videoShortSide
        let targetBitRate = Float(OptimaSettings.videoBitRate)

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let videos = PHAsset.fetchAssets(with: .video, options: options)

        // First the quick checks, using only what Photos already knows.
        var possible: [(PHAsset, PHAssetResource, Int64)] = []
        videos.enumerateObjects { asset, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            let resources = PHAssetResource.assetResources(for: asset)
            // Any subtype (slo-mo, time-lapse, Cinematic, screen recording…) except "streamed".
            guard asset.mediaSubtypes.subtracting(.videoStreamed).isEmpty,
                  min(asset.pixelWidth, asset.pixelHeight) >= minimumShortSide,
                  !resources.contains(where: { $0.type == .fullSizeVideo || $0.type == .adjustmentData }),
                  let original = resources.first(where: { $0.type == .video }),
                  let size = LibraryScanner.fileSize(of: original)
            else { return }
            possible.append((asset, original, size))
        }

        // Then open each remaining video to read its codec, bitrate and HDR.
        var candidates: [Candidate] = []
        for (asset, resource, size) in possible {
            if Task.isCancelled { break }
            guard let info = await videoInfo(of: asset) else { continue }
            let willShrink = min(asset.pixelWidth, asset.pixelHeight) > targetShortSide
            guard !info.isOptima, !info.isHDR,
                  info.codec == kCMVideoCodecType_H264 || (info.codec == kCMVideoCodecType_HEVC && willShrink),
                  info.bitRate > targetBitRate
            else { continue }
            let savings = Int64(Double(info.bitRate - targetBitRate) / 8 * asset.duration)
            candidates.append(Candidate(asset: asset, resource: resource, fileSize: size,
                                        videoBitRate: info.bitRate, estimatedSavings: savings))
        }
        return candidates
    }

    /// Copies the video's original file to a temporary file, downloading it from iCloud first
    /// if it isn't on this device. The caller deletes the file when done.
    static func exportOriginal(of candidate: Candidate) async throws -> URL {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: candidate.resource, toFile: file, options: options)
        return file
    }

    /// Codec, picture bitrate, HDR and Optima's marker of a video whose original is on this device;
    /// nil otherwise (scanning never downloads anything).
    private static func videoInfo(of asset: PHAsset) async
        -> (codec: CMVideoCodecType, bitRate: Float, isHDR: Bool, isOptima: Bool)? {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = false
        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
        guard let avAsset,
              let track = try? await avAsset.loadTracks(withMediaType: .video).first,
              let (formats, bitRate, characteristics) = try? await track.load(
                  .formatDescriptions, .estimatedDataRate, .mediaCharacteristics),
              let format = formats.first,
              let metadata = try? await avAsset.load(.metadata)
        else { return nil }
        return (CMFormatDescriptionGetMediaSubType(format), bitRate, characteristics.contains(.containsHDRVideo),
                VideoCompressor.isMarked(metadata))
    }
}
