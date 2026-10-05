//
//  LibraryVideosView.swift
//  Optima
//

import SwiftUI
import Photos

/// The Videos screen (Mac and iPhone): scans the library for videos worth compressing, then
/// compresses them to 720p HEVC and replaces them in batches. Every scan looks at the whole
/// library afresh, so new videos are picked up and ones already compressed are skipped.
struct LibraryVideosView: View {
    enum Phase: Equatable {
        case scanning
        case ready
        case compressing(done: Int, total: Int)
        case replacing(count: Int)
    }

    /// How many videos one click processes. Each batch is replaced in one step,
    /// so the system asks to confirm the delete once per batch. New files wait on the
    /// device's internal storage until the batch is replaced, so batches stay modest.
    static let batchSizes = [1, 3, 10, 25, 50]

    @State private var phase: Phase
    @State private var candidates: [VideoLibraryScanner.Candidate] = []
    @State private var batchSize = batchSizes[0]
    @State private var lastBatch: [CompressedVideo]
    @State private var bytesSaved: Int64 = 0
    @State private var videosReplaced = 0
    @State private var batchTask: Task<Void, Never>?
    @State private var scanTask: Task<Void, Never>?
    /// True when the last scan was stopped early, so the list may be incomplete.
    @State private var scanStopped = false
    @State private var errorMessage: String?
    /// These change which videos the scan includes, so the list is rescanned when they change.
    @AppStorage(OptimaSettings.Key.videoShortSide) private var videoShortSide = OptimaSettings.Default.videoShortSide
    @AppStorage(OptimaSettings.Key.videoBitRateMbps) private var videoBitRateMbps = OptimaSettings.Default.videoBitRateMbps

    init(phase: Phase = .scanning, lastBatch: [CompressedVideo] = []) {
        _phase = State(initialValue: phase)
        _lastBatch = State(initialValue: lastBatch)
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
                .padding()
            Divider()
            Group {
                if lastBatch.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Compressed Yet", systemImage: "film.stack")
                            .foregroundStyle(.tint)
                    } description: {
                        Text("Pick a batch size, then Compress. Each video is saved as \(videoShortSide)p HEVC at \(videoBitRateMbps) Mbps with its original sound and dates, and the original moves to Recently Deleted.")
                    }
                } else {
                    List(lastBatch) { CompressedVideoRow(video: $0) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controls
                .padding()
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        // Previews start in a fixed phase and skip the real scan.
        .task { if phase == .scanning { startScan() } }
        // A batch that's running rescans by itself when it ends.
        .onChange(of: [videoShortSide, videoBitRateMbps]) { if phase == .ready { startScan() } }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var summary: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if phase == .scanning {
                    Text("Scanning videos…").font(.title2.bold())
                } else {
                    Text("\(candidates.count) videos to compress\(scanStopped ? " (so far)" : "")").font(.title2.bold())
                    Text("\(bytes(candidates.reduce(0) { $0 + $1.fileSize })), about \(bytes(candidates.reduce(0) { $0 + $1.estimatedSavings })) can be saved")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if videosReplaced > 0 {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(bytes(bytesSaved)) saved").font(.title2.bold()).foregroundStyle(.tint)
                    Text("\(videosReplaced) videos replaced").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch phase {
        case .scanning:
            HStack {
                ProgressView().controlSize(.small)
                Spacer()
                // Keeps what was found so far; Rescan starts over.
                Button("Stop Scan") { scanTask?.cancel() }
            }
            .controlSize(.large)
        case .compressing(let done, let total):
            HStack {
                ProgressView(value: Double(done), total: Double(total)) {
                    Text("Compressing \(done + 1) of \(total)…")
                }
                Button("Stop") { batchTask?.cancel() }
            }
        case .replacing(let count):
            HStack {
                ProgressView().controlSize(.small)
                Text("Replacing \(count) videos… confirm the delete when asked.")
            }
        case .ready:
            BatchControls(batchSizes: Self.batchSizes, batchSize: $batchSize, noun: "video",
                          remaining: candidates.count,
                          rescan: startScan,
                          compress: { batchTask = Task { await compressNextBatch() } })
        }
    }

    // MARK: - Actions

    /// Starts a scan that the Stop Scan button can cancel. Switches to "scanning" right away,
    /// so the Rescan button can't be tapped twice.
    private func startScan() {
        phase = .scanning
        scanTask = Task { await scan() }
    }

    private func scan() async {
        phase = .scanning
        scanStopped = false
        defer { phase = .ready }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            errorMessage = LibraryScreen.fullAccessMessage
            return
        }
        // Videos that failed before (including ones that didn't get smaller) are never tried again.
        let failedIDs = FailureLog.failedIDs
        let found = await VideoLibraryScanner.findCandidates()
        candidates = found.filter { !failedIDs.contains($0.id) }
        scanStopped = Task.isCancelled
    }

    private func logFailure(_ candidate: VideoLibraryScanner.Candidate, reason: String) {
        FailureLog.record(fileName: candidate.fileName, id: candidate.id,
                          created: candidate.asset.creationDate, reason: reason)
    }

    /// Compresses the next batch, then replaces the originals in one step.
    /// Stopping partway still replaces the videos already compressed.
    private func compressNextBatch() async {
        let batch = Array(candidates.prefix(batchSize))
        var compressed: [CompressedVideo] = []
        var failures = 0
        LibraryScreen.keepScreenOn(true)
        defer { LibraryScreen.keepScreenOn(false) }

        for (index, candidate) in batch.enumerated() {
            if Task.isCancelled { break }
            phase = .compressing(done: index, total: batch.count)
            do {
                let original = try await VideoLibraryScanner.exportOriginal(of: candidate)
                defer { try? FileManager.default.removeItem(at: original) }
                let video = try await VideoCompressor.compress(original, assetIdentifier: candidate.id)
                // Never swap in a file that isn't actually smaller.
                if video.compressedByteCount < video.originalByteCount {
                    compressed.append(video)
                } else {
                    try? FileManager.default.removeItem(at: video.fileURL)
                    logFailure(candidate, reason: "Skipped: HEVC wasn't smaller (\(bytes(video.originalByteCount)) → \(bytes(video.compressedByteCount))).")
                }
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                logFailure(candidate, reason: "\(error.localizedDescription) [\(String(describing: error))]")
            }
        }

        if !compressed.isEmpty {
            phase = .replacing(count: compressed.count)
            do {
                let keptDateAdded = try await PhotoLibrarySaver.replaceOriginals(with: compressed)
                lastBatch = compressed
                videosReplaced += compressed.count
                bytesSaved += compressed.reduce(0) { $0 + $1.originalByteCount - $1.compressedByteCount }
                if !keptDateAdded {
                    errorMessage = "Videos were replaced, but Photos didn't keep their original \"date added\"."
                }
            } catch let error as PHPhotosError where error.code == .userCancelled {
                // The user declined the delete prompt — nothing was changed.
            } catch {
                errorMessage = error.localizedDescription
            }
            // Photos moved the files it used; delete any it didn't (declined or failed).
            for video in compressed {
                try? FileManager.default.removeItem(at: video.fileURL)
            }
        }
        if failures > 0 && errorMessage == nil {
            errorMessage = "\(failures) of \(batch.count) videos couldn't be compressed. They're listed in \(FailureLog.fileURL.path(percentEncoded: false)) and will be skipped from now on."
        }
        batchTask = nil
        // Replaced videos now carry Optima's marker, so a fresh scan drops them from the list.
        startScan()
    }

    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

#Preview("Ready, after a batch") {
    LibraryVideosView(phase: .ready, lastBatch: [.sample, .sample, .sample])
        .preferredColorScheme(.dark)
}

#Preview("Compressing") {
    LibraryVideosView(phase: .compressing(done: 3, total: 10))
        .preferredColorScheme(.dark)
}
