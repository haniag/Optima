//
//  VideoCompressor.swift
//  Optima
//

import AVFoundation
import Foundation
import VideoToolbox

/// Re-encodes videos as HEVC at the size and bitrate picked on the Settings tab (720p and 5 Mbps
/// unless changed), copying the sound unchanged and keeping the rotation and the file's own
/// metadata (date, location, camera). Each new file is tagged with Optima's `marker`.
nonisolated enum VideoCompressor {
    /// A metadata entry added to every new video, so library scans can tell Optima's
    /// videos apart and never compress one twice.
    static let marker: AVMetadataItem = {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.fursa.Optima.compressed" as NSString
        item.value = "Optima" as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }()

    /// True if the video carries Optima's `marker`.
    static func isMarked(_ metadata: [AVMetadataItem]) -> Bool {
        metadata.contains { $0.identifier == marker.identifier }
    }

    enum CompressionError: LocalizedError {
        case noVideoTrack
        case encodingFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The video has no picture to compress."
            case .encodingFailed(let error): "The video couldn't be saved as HEVC. \(error?.localizedDescription ?? "")"
            }
        }
    }

    /// Compresses the video file at `source` into a new temporary file, scaled down so its
    /// shortest side is at most `maxShortSide` pixels, at `bitRate` bits per second.
    /// Both default to the Settings tab's choices.
    /// Runs in the background. Cancelling the task stops the encode and deletes the partial file.
    @concurrent
    static func compress(_ source: URL, assetIdentifier: String?,
                         maxShortSide: Int = OptimaSettings.videoShortSide,
                         bitRate: Int = OptimaSettings.videoBitRate) async throws -> CompressedVideo {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompressionError.noVideoTrack
        }
        let (natural, transform, fps) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // naturalSize is the stored (unrotated) size; the rotation stays a transform on the track.
        // Sizes are rounded to even numbers, which the encoder needs.
        let scale = min(1, CGFloat(maxShortSide) / min(natural.width, natural.height))
        let width = Int((natural.width * scale / 2).rounded()) * 2
        let height = Int((natural.height * scale / 2).rounded()) * 2

        let output = URL.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.metadata = try await asset.load(.metadata) + [marker]

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ],
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        reader.add(videoOut)
        writer.add(videoIn)

        // Sound is copied as is (no re-encoding), so it loses nothing.
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOut, videoIn)]
        for track in audioTracks {
            let format = try await track.load(.formatDescriptions).first
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            reader.add(out)
            writer.add(input)
            pairs.append((out, input))
        }

        guard reader.startReading(), writer.startWriting() else {
            throw CompressionError.encodingFailed(reader.error ?? writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // Copy every track at the same time, each on its own queue, until all are done.
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (index, (out, input)) in pairs.enumerated() {
                    group.addTask {
                        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                            input.requestMediaDataWhenReady(on: DispatchQueue(label: "Optima.video.\(index)")) {
                                while input.isReadyForMoreMediaData {
                                    guard let sample = out.copyNextSampleBuffer(), input.append(sample) else {
                                        input.markAsFinished()
                                        done.resume()
                                        return
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } onCancel: {
            reader.cancelReading()
        }

        guard !Task.isCancelled, reader.status == .completed, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled { throw CancellationError() }
            throw CompressionError.encodingFailed(reader.error ?? writer.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.encodingFailed(writer.error)
        }

        return CompressedVideo(
            assetIdentifier: assetIdentifier,
            fileURL: output,
            originalByteCount: fileSize(source),
            compressedByteCount: fileSize(output),
            originalPixelSize: shown(natural, transform),
            newPixelSize: shown(CGSize(width: width, height: height), transform),
            duration: try await asset.load(.duration).seconds,
            thumbnail: await thumbnail(of: output)
        )
    }

    /// The size as the video is shown, after its rotation.
    private static func shown(_ size: CGSize, _ transform: CGAffineTransform) -> CGSize {
        let rotated = size.applying(transform)
        return CGSize(width: abs(rotated.width), height: abs(rotated.height))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
    }

    /// A small, correctly rotated frame from the start of the video.
    private static func thumbnail(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        return try? await generator.image(at: .zero).image
    }
}
