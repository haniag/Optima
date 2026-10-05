//
//  FailureLog.swift
//  Optima
//

import Foundation
import os

/// Keeps track of photos and videos that couldn't be compressed: writes one line per item to
/// Optima.log (and to Console.app), and remembers their IDs on this device so later scans
/// skip them.
enum FailureLog {
    private static let logger = Logger(subsystem: "com.fursa.Optima", category: "Compression")
    private static let failedIDsKey = "failedPhotoIDs"

    /// Library/Logs/Optima.log. The Mac app is sandboxed, so this lands in
    /// ~/Library/Containers/com.fursa.Optima/Data/Library/Logs/Optima.log.
    static var fileURL: URL {
        URL.libraryDirectory.appending(path: "Logs/Optima.log")
    }

    /// IDs of every photo that has failed so far (kept across app launches).
    static var failedIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: failedIDsKey) ?? [])
    }

    static func record(fileName: String, id: String, created: Date?, reason: String) {
        var ids = failedIDs
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: failedIDsKey)

        let taken = created?.formatted(date: .abbreviated, time: .shortened) ?? "unknown date"
        let line = "\(Date.now.ISO8601Format())  \(fileName)  (taken \(taken), id \(id))  \(reason)\n"
        logger.error("\(line, privacy: .public)")
        append(line)
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            logger.error("Couldn't write Optima.log: \(error.localizedDescription, privacy: .public)")
        }
    }
}
