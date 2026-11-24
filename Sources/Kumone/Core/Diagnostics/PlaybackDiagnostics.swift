import Foundation
import os.log

// MARK: - 播放诊断日志
//
// 记录播放解析链每一步：官方接口结果、每个 LX 音源的结果与耗时、
// 内置解锁源、最终 URL、播放失败原因。可导出为文本文件供排查。

struct DiagnosticEntry: Codable, Hashable {
    let time: String
    let category: String
    let message: String
}

final class PlaybackDiagnostics {
    static let shared = PlaybackDiagnostics()

    private let lock = NSLock()
    private var entries: [DiagnosticEntry] = []
    private let maxEntries = 800
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func log(_ category: String, _ message: String) {
        let entry = DiagnosticEntry(time: dateFormatter.string(from: Date()),
                                    category: category, message: message)
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        lock.unlock()
        NSLog("[诊断·\(category)] \(message)")
    }

    func allEntries() -> [DiagnosticEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// 导出为纯文本文件，写入 Documents 并返回 URL。
    func exportFile() -> URL? {
        let text = exportedText()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = docs.appendingPathComponent("Kumone诊断日志-\(fmt.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
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
