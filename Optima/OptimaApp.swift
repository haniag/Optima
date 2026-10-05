//
//  OptimaApp.swift
//  Optima
//
//  Created by hani on 9/29/26.
//

import SwiftUI

@main
struct OptimaApp: App {
    var body: some Scene {
        WindowGroup {
            // Mac and iPhone both compress the whole library in batches, with the same settings.
            TabView {
                Tab("Photos", systemImage: "photo") { LibraryPhotosView() }
                Tab("Videos", systemImage: "video") { LibraryVideosView() }
                #if os(iOS)
                // Compress photos picked by hand.
                Tab("Select", systemImage: "photo.on.rectangle") { ContentView() }
                #endif
                Tab("Settings", systemImage: "gearshape") { SettingsView() }
            }
            // Always use the dark look, even if the device is in light mode.
            .preferredColorScheme(.dark)
        }
    }
}
