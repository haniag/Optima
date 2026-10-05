//
//  LibraryPhotosView.swift
//  Optima
//

import SwiftUI
import Photos

/// The Photos screen (Mac and iPhone): scans the whole library for photos worth compressing,
/// then compresses and replaces them in batches. Every scan looks at the whole library afresh,
/// so new photos are picked up and ones already compressed are skipped.
struct LibraryPhotosView: View {
    enum Phase: Equatable {
        case scanning
        case ready
        case compressing(done: Int, total: Int)
        case replacing(count: Int)
    }

    /// How many photos one click processes. Each batch is replaced in one step,
    /// so the system asks to confirm the delete once per batch.
    static let batchSizes = [5, 10, 50, 100, 250]

    @State private var phase: Phase
    @State private var candidates: [LibraryScanner.Candidate] = []
    @State private var batchSize = batchSizes[0]
    @State private var lastBatch: [CompressedPhoto]
    @State private var bytesSaved: Int64 = 0
    @State private var photosReplaced = 0
    @State private var batchTask: Task<Void, Never>?
    @State private var scanTask: Task<Void, Never>?
    /// True when the last scan was stopped early, so the list may be incomplete.
    @State private var scanStopped = false
    @State private var errorMessage: String?
    /// Changes which photos the scan includes, so the list is rescanned when it changes.
    @AppStorage(OptimaSettings.Key.recompressHEIC) private var recompressHEIC = OptimaSettings.Default.recompressHEIC

    init(phase: Phase = .scanning, lastBatch: [CompressedPhoto] = []) {
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
                        Label("Nothing Compressed Yet", systemImage: "photo.stack")
                            .foregroundStyle(.tint)
                    } description: {
                        Text("Pick a batch size, then Compress. Each photo is saved as HEIC at full resolution with its original dates, and the original moves to Recently Deleted.")
                    }
                } else {
                    List(lastBatch) { CompressedPhotoRow(photo: $0) }
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
        .onChange(of: recompressHEIC) { if phase == .ready { startScan() } }
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
                    Text("Scanning library…").font(.title2.bold())
                } else {
                    Text("\(candidates.count) photos to compress\(scanStopped ? " (so far)" : "")").font(.title2.bold())
                    Text("\(bytes(candidates.reduce(0) { $0 + $1.fileSize })) of \(recompressHEIC ? "JPEG and camera HEIC" : "JPEG") photos over 1.5 MB")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if photosReplaced > 0 {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(bytes(bytesSaved)) saved").font(.title2.bold()).foregroundStyle(.tint)
                    Text("\(photosReplaced) photos replaced").foregroundStyle(.secondary)
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
                    Text("Compressing \(done) of \(total)…")
                }
                Button("Stop") { batchTask?.cancel() }
            }
        case .replacing(let count):
            HStack {
                ProgressView().controlSize(.small)
                Text("Replacing \(count) photos… confirm the delete when asked.")
            }
        case .ready:
            BatchControls(batchSizes: Self.batchSizes, batchSize: $batchSize, noun: "photo",
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
        // Photos that failed before (including ones that didn't get smaller) are never tried again.
        let failedIDs = FailureLog.failedIDs
        let found = await LibraryScanner.findCandidates()
        candidates = found.filter { !failedIDs.contains($0.id) }
        scanStopped = Task.isCancelled
    }

    private func logFailure(_ candidate: LibraryScanner.Candidate, reason: String) {
        FailureLog.record(fileName: candidate.fileName, id: candidate.id,
                          created: candidate.asset.creationDate, reason: reason)
    }

    /// Compresses the next batch, then replaces the originals in one step.
    /// Stopping partway still replaces the photos already compressed.
    private func compressNextBatch() async {
        let batch = Array(candidates.prefix(batchSize))
        var compressed: [CompressedPhoto] = []
        var failures = 0
        LibraryScreen.keepScreenOn(true)
        defer { LibraryScreen.keepScreenOn(false) }

        for (index, candidate) in batch.enumerated() {
            if Task.isCancelled { break }
            phase = .compressing(done: index, total: batch.count)
            do {
                let original = try await LibraryScanner.originalData(of: candidate.asset)
                // Full resolution, at the HEIC quality picked in Settings.
                let photo = try await PhotoCompressor.compress(original, assetIdentifier: candidate.id)
                // Never swap in a file that isn't actually smaller.
                if photo.compressedByteCount < photo.originalByteCount {
                    compressed.append(photo)
                } else {
                    logFailure(candidate, reason: "Skipped: HEIC wasn't smaller (\(bytes(Int64(photo.originalByteCount))) → \(bytes(Int64(photo.compressedByteCount)))).")
                }
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
                photosReplaced += compressed.count
                bytesSaved += Int64(compressed.reduce(0) { $0 + $1.originalByteCount - $1.compressedByteCount })
                if !keptDateAdded {
                    errorMessage = "Photos were replaced, but Photos didn't keep their original \"date added\"."
                }
            } catch let error as PHPhotosError where error.code == .userCancelled {
                // The user declined the delete prompt — nothing was changed.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if failures > 0 && errorMessage == nil {
            errorMessage = "\(failures) of \(batch.count) photos couldn't be compressed. They're listed in \(FailureLog.fileURL.path(percentEncoded: false)) and will be skipped from now on."
        }
        batchTask = nil
        // Replaced photos now carry Optima's marker, so a fresh scan drops them from the list.
        startScan()
    }

    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

#Preview("Ready, after a batch") {
    LibraryPhotosView(phase: .ready, lastBatch: [.sample, .sample, .sample])
        .preferredColorScheme(.dark)
}

#Preview("Compressing") {
    LibraryPhotosView(phase: .compressing(done: 37, total: 100))
        .preferredColorScheme(.dark)
}
