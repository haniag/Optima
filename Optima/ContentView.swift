//
//  ContentView.swift
//  Optima
//
//  Created by hani on 9/29/26.
//

import SwiftUI
import PhotosUI
import Photos

struct ContentView: View {
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photos: [CompressedPhoto]
    @State private var isCompressing = false
    @State private var isSaving = false
    @State private var isSaved = false
    @State private var errorMessage: String?

    init(photos: [CompressedPhoto] = []) {
        _photos = State(initialValue: photos)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isCompressing {
                    ProgressView("Compressing…")
                        .tint(.accentColor)
                } else if photos.isEmpty {
                    ContentUnavailableView {
                        Label("No Photos Selected", systemImage: "photo.on.rectangle.angled")
                            .foregroundStyle(.tint)
                    } description: {
                        Text("Photos are saved as HEIC at full resolution, keeping their EXIF data. Ones that wouldn't get smaller are left out.")
                    }
                } else {
                    List(photos) {
                        CompressedPhotoRow(photo: $0)
                            .listRowBackground(Color.black)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .navigationTitle("Optima")
            .safeAreaInset(edge: .bottom) { bottomButtons }
            // Runs every time the selection changes.
            .task(id: pickerItems) { await compressSelection() }
            .alert("Something went wrong", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var bottomButtons: some View {
        VStack(spacing: 12) {
            if !photos.isEmpty && !isCompressing {
                Button {
                    Task { await replaceOriginals() }
                } label: {
                    Label(isSaved ? "Originals Replaced" : "Replace Originals",
                          systemImage: isSaved ? "checkmark" : "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || isSaved)
            }

            // `.current` asks for the original file, so we get the real EXIF data
            // instead of a converted copy. `photoLibrary: .shared()` tells us which
            // library photo was picked, so we can replace it later.
            PhotosPicker(selection: $pickerItems, matching: .images,
                         preferredItemEncoding: .current, photoLibrary: .shared()) {
                Label("Select Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isCompressing || isSaving)
        }
        .controlSize(.large)
        .padding()
    }

    private func compressSelection() async {
        guard !pickerItems.isEmpty else { return }
        isCompressing = true
        defer { isCompressing = false }
        photos = []
        isSaved = false

        var failures = 0
        var notSmaller = 0
        var skippedHEIC = 0
        let includeHEIC = OptimaSettings.recompressHEIC
        for item in pickerItems {
            // With "Re-compress existing HEICs" off in Settings, only JPEGs are compressed.
            if !includeHEIC, item.supportedContentTypes.contains(where: LibraryScanner.isHEIC) {
                skippedHEIC += 1
                continue
            }
            do {
                guard let original = try await item.loadTransferable(type: Data.self) else {
                    failures += 1
                    continue
                }
                let photo = try await PhotoCompressor.compress(original, assetIdentifier: item.itemIdentifier)
                // Never swap in a file that isn't actually smaller (e.g. a photo compressed before).
                if photo.compressedByteCount < photo.originalByteCount {
                    photos.append(photo)
                } else {
                    notSmaller += 1
                }
            } catch {
                failures += 1
            }
            if Task.isCancelled { return }
        }
        if failures > 0 || notSmaller > 0 || skippedHEIC > 0 {
            errorMessage = [
                failures > 0 ? "\(failures) of \(pickerItems.count) photos couldn't be compressed." : nil,
                notSmaller > 0 ? "\(notSmaller) of \(pickerItems.count) photos were left out because they wouldn't get smaller." : nil,
                skippedHEIC > 0 ? "\(skippedHEIC) of \(pickerItems.count) photos were left out because they're already HEIC (see Settings)." : nil,
            ].compactMap(\.self).joined(separator: " ")
        }
    }

    private func replaceOriginals() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let keptDateAdded = try await PhotoLibrarySaver.replaceOriginals(with: photos)
            isSaved = true
            if !keptDateAdded {
                errorMessage = "Photos were replaced, but iOS didn't keep their original \"date added\", so they'll appear as recently added."
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            // The user tapped "Don't Allow" on iOS's delete prompt — nothing was changed.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Empty") {
    ContentView().preferredColorScheme(.dark)
}

#Preview("With photos") {
    ContentView(photos: [.sample, .sample, .sample]).preferredColorScheme(.dark)
}
