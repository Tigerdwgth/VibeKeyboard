// FileLogger.swift
// VibeKeyboard — File-based logging for ad-hoc signed apps
//
// NSLog output is silently dropped by macOS for ad-hoc codesigned apps.
// This logger writes to ~/voice-input-mac/vibekeyboard.log so we can
// diagnose issues via SSH.

import Foundation

/// Simple file logger that appends timestamped lines to a log file.
/// Thread-safe via a serial dispatch queue.
enum FileLogger {

    private static let queue = DispatchQueue(label: "com.gsj.vibekeyboard.logger")

    private static let logURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("voice-input-mac/vibekeyboard.log")
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Append a log line.  Also forwards to NSLog (which may or may not appear).
    static func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        // NSLog as well (useful when running from terminal)
        NSLog("[VK] %{public}@", message)

        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    /// Truncate the log file (call on app launch to avoid unbounded growth).
    static func truncate() {
        queue.async {
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
