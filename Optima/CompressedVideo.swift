//
//  CompressedVideo.swift
//  Optima
//

import CoreGraphics
import Foundation

/// One video after it has been re-encoded as 720p HEVC, waiting in a temporary file
/// until it replaces the original in the library.
/// `@unchecked Sendable` because CGImage is an immutable image, safe to share between threads.
nonisolated struct CompressedVideo: Identifiable, @unchecked Sendable {
    let id = UUID()
    /// The original video's ID in the photo library, used to replace it.
    let assetIdentifier: String?
    /// The new video file (in the temporary folder; Photos moves it into the library).
    let fileURL: URL
    let originalByteCount: Int64
    let compressedByteCount: Int64
    /// Sizes as the video is shown (portrait videos are taller than wide).
    let originalPixelSize: CGSize
    let newPixelSize: CGSize
    /// Length in seconds.
    let duration: Double
    /// A small preview frame for the list.
    let thumbnail: CGImage?

    /// How much smaller the new file is, from 0 to 1.
    var savings: Double {
        guard originalByteCount > 0 else { return 0 }
        return 1 - Double(compressedByteCount) / Double(originalByteCount)
    }
}

extension CompressedVideo {
    /// Placeholder values for SwiftUI previews (no real video file).
    static let sample = CompressedVideo(
        assetIdentifier: nil,
        fileURL: URL(filePath: "/dev/null"),
        originalByteCount: 88_500_000,
        compressedByteCount: 24_700_000,
        originalPixelSize: CGSize(width: 1440, height: 1920),
        newPixelSize: CGSize(width: 720, height: 960),
        duration: 34,
        thumbnail: nil
    )
}
