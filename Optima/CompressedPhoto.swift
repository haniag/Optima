//
//  CompressedPhoto.swift
//  Optima
//

import Foundation

/// One photo after it has been resized and re-encoded as HEIC.
nonisolated struct CompressedPhoto: Identifiable, Sendable {
    let id = UUID()
    /// The original photo's ID in the photo library, used to replace it.
    let assetIdentifier: String?
    /// The HEIC file bytes, including the original EXIF / GPS metadata.
    let data: Data
    let originalByteCount: Int
    let originalPixelSize: CGSize
    let newPixelSize: CGSize

    var compressedByteCount: Int { data.count }

    /// How much smaller the new file is, from 0 to 1.
    var savings: Double {
        guard originalByteCount > 0 else { return 0 }
        return 1 - Double(compressedByteCount) / Double(originalByteCount)
    }
}

extension CompressedPhoto {
    /// Placeholder values for SwiftUI previews (no real image data).
    static let sample = CompressedPhoto(
        assetIdentifier: nil,
        data: Data(count: 1_150_000),
        originalByteCount: 3_400_000,
        originalPixelSize: CGSize(width: 4032, height: 3024),
        newPixelSize: CGSize(width: 2822, height: 2117)
    )
}
