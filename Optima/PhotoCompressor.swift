//
//  PhotoCompressor.swift
//  Optima
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes photos as HEIC (at full resolution by default), copying the original
/// metadata (EXIF, GPS, TIFF, orientation) into the new file and tagging it with Optima's `marker`.
/// The quality comes from the Settings tab, on both Mac and iPhone.
nonisolated enum PhotoCompressor {
    /// New width and height as a fraction of the original, unless the caller passes its own.
    static let defaultScale = 1.0
    /// Written into each new file's EXIF "User Comment", so library scans can tell
    /// Optima's files apart and never compress a photo twice.
    static let marker = "Optima"

    /// Extra layers stored inside a photo besides the main image:
    /// HDR gain maps (brighter highlights on HDR screens) and Portrait mode depth / mattes.
    private static let auxiliaryDataTypes: [CFString] = [
        kCGImageAuxiliaryDataTypeHDRGainMap,
        kCGImageAuxiliaryDataTypeISOGainMap,
        kCGImageAuxiliaryDataTypeDepth,
        kCGImageAuxiliaryDataTypeDisparity,
        kCGImageAuxiliaryDataTypePortraitEffectsMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
    ]

    enum CompressionError: LocalizedError {
        case unreadableImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "The photo couldn't be read."
            case .encodingFailed: "The photo couldn't be saved as HEIC."
            }
        }
    }

    /// `scale` is the new width and height as a fraction of the original; 1 keeps full resolution.
    /// `quality` is the HEIC quality from 0.1 (smallest) to 1 (best), used whether or not
    /// the photo is resized; by default it's the one picked on the Settings tab.
    /// Runs on a background thread so the UI stays responsive.
    @concurrent
    static func compress(_ original: Data, assetIdentifier: String?,
                         scale: Double = defaultScale,
                         quality: Double = OptimaSettings.photoQuality) async throws -> CompressedPhoto {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight] as? Int
        else { throw CompressionError.unreadableImage }

        // Downscale so the longest side is `scale` × the original; the other side follows
        // proportionally. Pixels are kept in their stored orientation so the original
        // EXIF orientation tag still displays the photo the right way up.
        let resizeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: Int((Double(max(width, height)) * scale).rounded()),
        ]
        guard let resized = CGImageSourceCreateThumbnailAtIndex(source, 0, resizeOptions as CFDictionary) else {
            throw CompressionError.unreadableImage
        }

        // Start from the original metadata and only update the pixel dimensions,
        // plus Optima's marker (unless the photo already has a comment of its own).
        var newMetadata = metadata
        newMetadata[kCGImagePropertyPixelWidth] = resized.width
        newMetadata[kCGImagePropertyPixelHeight] = resized.height
        var exif = newMetadata[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = resized.width
        exif[kCGImagePropertyExifPixelYDimension] = resized.height
        if exif[kCGImagePropertyExifUserComment] == nil {
            exif[kCGImagePropertyExifUserComment] = marker
        }
        newMetadata[kCGImagePropertyExifDictionary] = exif
        newMetadata[kCGImageDestinationLossyCompressionQuality] = quality

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil) else {
            throw CompressionError.encodingFailed
        }
        CGImageDestinationAddImage(destination, resized, newMetadata as CFDictionary)

        // Copy the hidden layers iPhone photos carry. They're stretched to fit the main
        // image when used, so they still line up after the resize without changes.
        for type in auxiliaryDataTypes {
            if let layer = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) {
                CGImageDestinationAddAuxiliaryDataInfo(destination, type, layer)
            }
        }

        guard CGImageDestinationFinalize(destination) else { throw CompressionError.encodingFailed }

        return CompressedPhoto(
            assetIdentifier: assetIdentifier,
            data: output as Data,
            originalByteCount: original.count,
            originalPixelSize: CGSize(width: width, height: height),
            newPixelSize: CGSize(width: resized.width, height: resized.height)
        )
    }

    /// A small, correctly rotated preview image for showing in the list.
    @concurrent
    static func thumbnail(of data: Data, maxPixelSize: Int = 160) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
