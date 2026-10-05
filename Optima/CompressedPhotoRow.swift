//
//  CompressedPhotoRow.swift
//  Optima
//

import SwiftUI

/// A list row showing a photo's thumbnail and its before → after size.
struct CompressedPhotoRow: View {
    let photo: CompressedPhoto
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(bytes(photo.originalByteCount)) → \(bytes(photo.compressedByteCount))")
                    .font(.headline)
                Text("\(pixels(photo.originalPixelSize)) → \(pixels(photo.newPixelSize))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Shown as a change in size, e.g. "-65%".
            Text(-photo.savings, format: .percent.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(photo.savings > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .task { thumbnail = await PhotoCompressor.thumbnail(of: photo.data) }
    }

    private func bytes(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .file))
    }

    private func pixels(_ size: CGSize) -> String {
        "\(Int(size.width))×\(Int(size.height))"
    }
}

#Preview {
    List {
        CompressedPhotoRow(photo: .sample)
    }
}
