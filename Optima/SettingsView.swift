//
//  SettingsView.swift
//  Optima
//

import SwiftUI

/// The settings the user can change. Saved automatically and used by the next scan or batch;
/// the library tabs rescan on their own when a setting changes which items they list.
struct SettingsView: View {
    @AppStorage(OptimaSettings.Key.photoQuality) private var photoQuality = OptimaSettings.Default.photoQuality
    @AppStorage(OptimaSettings.Key.recompressHEIC) private var recompressHEIC = OptimaSettings.Default.recompressHEIC
    @AppStorage(OptimaSettings.Key.videoShortSide) private var videoShortSide = OptimaSettings.Default.videoShortSide
    @AppStorage(OptimaSettings.Key.videoBitRateMbps) private var videoBitRateMbps = OptimaSettings.Default.videoBitRateMbps

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Quality", value: photoQuality, format: .number.precision(.fractionLength(1)))
                    Slider(value: $photoQuality, in: 0.1...1.0, step: 0.1) {
                        Text("Quality")
                    } minimumValueLabel: {
                        Text("0.1")
                    } maximumValueLabel: {
                        Text("1.0")
                    }
                    .labelsHidden()
                    Toggle("Re-compress existing HEICs", isOn: $recompressHEIC)
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Lower quality makes smaller files. Photos are always saved as HEIC at full resolution. When re-compressing is off, only JPEG photos are compressed.")
                }

                Section {
                    Picker("Video size", selection: $videoShortSide) {
                        ForEach(OptimaSettings.videoShortSides, id: \.self) { Text("\($0)p") }
                    }
                    Picker("Bitrate", selection: $videoBitRateMbps) {
                        ForEach(OptimaSettings.videoBitRatesMbps, id: \.self) { Text("\($0) Mbps") }
                    }
                } header: {
                    Text("Videos")
                } footer: {
                    Text("Videos are saved as HEVC, scaled down so their shortest side is at most this size.")
                }

                Section("Optima runs based on these rules:") {
                    rules("Photo", [
                        "A JPEG photo or an HEIC/HEIF that hasn't been compressed before.",
                        "Photo larger than 1.5 MB.",
                        "Photo Hasn't been edited in Photos app.",
                        "Skip: Panoramas, Live Photos, Portraits, Screenshots, Selfies, Burst photos, and any HEIC whose EXIF can't be read.",
                    ])
                    rules("Video", [
                        "Shortest side is 720 or above.",
                        "Not edited in Photos app.",
                        "Codec is H.264 or HEVC and hasn't been compressed before.",
                        "Skip: Slo-mo, Time-lapse, Cinematic, HDR, and Screen recordings.",
                    ])
                }

                Section {
                    Button("Restore Defaults") {
                        photoQuality = OptimaSettings.Default.photoQuality
                        recompressHEIC = OptimaSettings.Default.recompressHEIC
                        videoShortSide = OptimaSettings.Default.videoShortSide
                        videoBitRateMbps = OptimaSettings.Default.videoBitRateMbps
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
    }

    /// A heading followed by one line per rule, each starting with a dash.
    private func rules(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(lines, id: \.self) { Text("- \($0)") }
        }
        .font(.callout)
        .padding(.vertical, 2)
    }
}

#Preview {
    SettingsView().preferredColorScheme(.dark)
}
