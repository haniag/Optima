//
//  LibraryScreen.swift
//  Optima
//

import SwiftUI

/// Pieces shared by the Photos and Videos library screens, on both Mac and iPhone.
enum LibraryScreen {
    /// Shown when Optima doesn't have Full Access to the library.
    static var fullAccessMessage: String {
        #if os(macOS)
        "Optima needs Full Access to your photos. You can allow it in System Settings › Privacy & Security › Photos."
        #else
        "Optima needs Full Access to your photos. You can allow it in Settings › Apps › Optima › Photos."
        #endif
    }

    /// Keeps the iPhone's screen on while a batch runs: if the phone locks,
    /// iOS pauses Optima and the batch stops partway. Does nothing on the Mac.
    static func keepScreenOn(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

/// The batch size picker with the Rescan and Compress buttons. All on one row when there's
/// room (Mac); on a narrow screen (iPhone) the Compress button gets a full-width row of its own.
struct BatchControls: View {
    let batchSizes: [Int]
    @Binding var batchSize: Int
    /// What's being compressed, singular: "photo" or "video".
    let noun: String
    /// How many items are left to compress.
    let remaining: Int
    let rescan: () -> Void
    let compress: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                picker
                Spacer()
                rescanButton
                compressButton(fullWidth: false)
            }
            VStack(spacing: 12) {
                HStack {
                    picker
                    Spacer()
                    rescanButton
                }
                compressButton(fullWidth: true)
            }
        }
        .controlSize(.large)
    }

    private var picker: some View {
        Picker("Batch size", selection: $batchSize) {
            ForEach(batchSizes, id: \.self) { Text(items($0)) }
        }
        .fixedSize()
    }

    private var rescanButton: some View {
        Button("Rescan", action: rescan)
    }

    private func compressButton(fullWidth: Bool) -> some View {
        Button(action: compress) {
            Label("Compress \(items(min(batchSize, remaining)).capitalized)", systemImage: "arrow.down.right.and.arrow.up.left")
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .disabled(remaining == 0)
    }

    /// "1 photo", "10 photos".
    private func items(_ count: Int) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

#Preview {
    BatchControls(batchSizes: [10, 50], batchSize: .constant(10), noun: "photo",
                  remaining: 120, rescan: {}, compress: {})
        .padding()
        .preferredColorScheme(.dark)
}
