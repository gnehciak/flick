import Foundation

/// Timing log, only active when FLICK_LOG is set.
enum Log {
    static let path = ProcessInfo.processInfo.environment["FLICK_LOG"]
    private static let q = DispatchQueue(label: "flick.log", qos: .background)

    static func write(_ text: @autoclosure () -> String) {
        guard let path else { return }
        let line = String(format: "%.3f ", Double(now()) / 1e9) + text() + "\n"
        q.async {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
            }
        }
    }
}
