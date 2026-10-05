//
//  OptimaSettings.swift
//  Optima
//

import Foundation

/// The settings the user can change on the Settings tab, saved in UserDefaults so they're
/// kept across launches. Every other setting is fixed in code. `nonisolated` so the
/// compressors and scanners can read them from background threads (UserDefaults is thread-safe).
nonisolated enum OptimaSettings {
    /// UserDefaults keys, also used by the Settings tab's `@AppStorage`.
    enum Key {
        static let photoQuality = "photoQuality"
        static let recompressHEIC = "recompressHEIC"
        static let videoShortSide = "videoShortSide"
        static let videoBitRateMbps = "videoBitRateMbps"
    }

    /// Values used until the user changes them (the same as the old hard-coded settings).
    enum Default {
        static let photoQuality = 0.6
        static let recompressHEIC = true
        static let videoShortSide = 720
        static let videoBitRateMbps = 5
    }

    /// The choices offered on the Settings tab.
    static let videoShortSides = [720, 1080]
    static let videoBitRatesMbps = [1, 2, 3, 4, 5, 6, 7]

    /// HEIC quality from 0.1 (smallest) to 1 (best), used for every photo compressed.
    static var photoQuality: Double {
        UserDefaults.standard.object(forKey: Key.photoQuality) as? Double ?? Default.photoQuality
    }

    /// When false, photos that are already HEIC are left alone; only JPEGs are compressed.
    static var recompressHEIC: Bool {
        UserDefaults.standard.object(forKey: Key.recompressHEIC) as? Bool ?? Default.recompressHEIC
    }

    /// Videos are scaled down so their shortest side is at most this many pixels.
    static var videoShortSide: Int {
        UserDefaults.standard.object(forKey: Key.videoShortSide) as? Int ?? Default.videoShortSide
    }

    /// The new videos' bitrate in bits per second.
    static var videoBitRate: Int {
        let mbps = UserDefaults.standard.object(forKey: Key.videoBitRateMbps) as? Int ?? Default.videoBitRateMbps
        // A saved value that's no longer offered falls back to the default.
        return (videoBitRatesMbps.contains(mbps) ? mbps : Default.videoBitRateMbps) * 1_000_000
    }
}
