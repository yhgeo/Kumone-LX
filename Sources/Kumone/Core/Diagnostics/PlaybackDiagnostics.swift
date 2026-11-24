import Foundation
import os.log

// MARK: - 播放诊断日志
//
// 记录播放解析链每一步：官方接口结果、每个 LX 音源的结果与耗时、
// 内置解锁源、最终 URL、播放失败原因。追加式文本落盘，App 重启不丢，可导出。

struct DiagnosticEntry: Codable, Hashable {
    let time: String
    let category: String
    let message: String
}

final class PlaybackDiagnostics {
    static let shared = PlaybackDiagnostics()

    private let lock = NSLock()
    private var entries: [DiagnosticEntry] = []
    private let maxEntries = 2000
    /// 追加式文本日志：每条直接 append，绝不被整文件重写覆盖。
    private let textFile: URL
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        textFile = docs.appendingPathComponent("playback-diagnostics.txt")
        load()
        log("系统", "App 启动 / 日志系统就绪 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
    }

    /// 从文本日志恢复（按行解析）。
    private func load() {
        guard let text = try? String(contentsOf: textFile, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("["),
                  let close1 = line.firstIndex(of: "]") else { continue }
            let time = String(line[line.index(after: line.startIndex)..<close1])
            let rest = line[line.index(after: close1)...]
            guard rest.hasPrefix("["), let close2 = rest.firstIndex(of: "]") else { continue }
            let category = String(rest[rest.index(after: rest.startIndex)..<close2])
            let message = String(rest[rest.index(after: close2)...]).trimmingCharacters(in: .whitespaces)
            entries.append(DiagnosticEntry(time: time, category: category, message: message))
        }
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    /// 追加一行到文本文件（不重写整个文件，避免并发覆盖）。
    private func appendToDisk(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: textFile) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: textFile, options: .atomic) // 首次创建
        }
    }

    func log(_ category: String, _ message: String) {
        let time = dateFormatter.string(from: Date())
        let entry = DiagnosticEntry(time: time, category: category, message: message)
        let line = "[\(time)] [\(category)] \(message)"
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        appendToDisk(line)
        lock.unlock()
        NSLog("[诊断·\(category)] \(message)")
    }

    func allEntries() -> [DiagnosticEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        try? FileManager.default.removeItem(at: textFile)
        lock.unlock()
    }

    func exportFile() -> URL? {
        let text = exportedText()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = docs.appendingPathComponent("Kumone诊断日志-\(fmt.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    func exportedText() -> String {
        let header = """
        ===== Kumone-LX 播放诊断日志 =====
        导出时间：\(dateFormatter.string(from: Date()))
        App 版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        系统：iOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        条目数：\(allEntries().count)
        =====================================

        """
        let body = allEntries().map { "[\($0.time)] [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
        return header + body + "\n"
    }
}
