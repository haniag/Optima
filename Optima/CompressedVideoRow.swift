//
//  CompressedVideoRow.swift
//  Optima
//

import SwiftUI

/// A list row showing a video's first frame, its before → after size, resolution and length.
struct CompressedVideoRow: View {
    let video: CompressedVideo

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail = video.thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "video").foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(bytes(video.originalByteCount)) → \(bytes(video.compressedByteCount))")
                    .font(.headline)
                Text("\(pixels(video.originalPixelSize)) → \(pixels(video.newPixelSize)) · \(length(video.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Shown as a change in size, e.g. "-65%".
            Text(-video.savings, format: .percent.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(video.savings > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    private func pixels(_ size: CGSize) -> String {
        "\(Int(size.width))×\(Int(size.height))"
    }

    private func length(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

#Preview {
    List {
        CompressedVideoRow(video: .sample)
    }
}
