import Foundation

/// Диагностический лог в контейнере App Group (`diag.log`): пишут приложение, виджеты и интенты.
/// Свой лёгкий lock (не flock DayStore); запись — одной строкой через O_APPEND; ~500 последних строк.
enum DiagLog {
    static let maxLines = 500
    private static let lock = NSLock()
    private static var writes = 0
    static var url: URL { VajraConfig.containerURL().appendingPathComponent("diag.log") }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var process: String {
        let id = Bundle.main.bundleIdentifier ?? "?"
        return id.hasSuffix(".widgets") ? "widgets" : (id == "com.maxdzhabali.vajra" ? "app" : id)
    }

    static func log(_ event: String, _ details: String = "") {
        guard !VajraConfig.isTesting else { return }
        let line = "\(fmt.string(from: Date())) [\(process)] \(event)\(details.isEmpty ? "" : " — " + details)\n"
        lock.withLock {
            let path = url.path
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            let data = Array(line.utf8)
            _ = data.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            writes += 1
            if writes % 50 == 0 { rotate() }
        }
    }

    private static func rotate() {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxLines else { return }
        try? (lines.suffix(maxLines).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func tail(_ n: Int = 60) -> String {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.split(separator: "\n").suffix(n).joined(separator: "\n")
    }

    static func clear() { lock.withLock { try? Data().write(to: url) } }

    /// Последние 2 компонента пути контейнера — видно, общий ли контейнер у процессов.
    static var containerTail: String {
        VajraConfig.containerURL().pathComponents.suffix(2).joined(separator: "/")
    }
}
