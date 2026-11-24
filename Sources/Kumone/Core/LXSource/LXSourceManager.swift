import Foundation
import os.log

// MARK: - LX 自定义音源管理器
//
// 负责：音源脚本的持久化（导入/删除/启用列表）、把脚本交给引擎加载、
// 以及对外提供"用已启用音源解析歌曲播放地址"的统一入口。
// 脚本来源：pdone/lx-music-source 等仓库的 latest.js 原文。

final class LXSourceManager: ObservableObject {
    static let shared = LXSourceManager()

    @Published private(set) var sources: [LXSourceMeta] = []
    @Published private(set) var enabledKeys: Set<String> = []
    @Published var lastError: String?

    private let log = Logger(subsystem: "sb.moe.kumone", category: "lx-source-mgr")
    private let engine = LXSourceEngine.shared
    private let fm = FileManager.default
    private let root: URL
    private let enabledKey = "lx.enabledSources"

    init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        root = docs.appendingPathComponent("LXSources", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        loadPersisted()
        let saved = UserDefaults.standard.stringArray(forKey: enabledKey) ?? []
        enabledKeys = Set(saved)
    }

    private func fileURL(for key: String) -> URL {
        root.appendingPathComponent("\(key).js")
    }

    private var validKey: CharacterSet { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")) }

    /// 从脚本原文导入一个音源。key 由 @name 或传入键名生成，只保留安全字符。
    @discardableResult
    func importScript(_ raw: String, key providedKey: String? = nil) async -> LXSourceMeta? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run { lastError = "脚本内容为空" }
            return nil
        }
        // 先让引擎解析元信息（解析 @name/@version），同时完成脚本初始化
        let baseKey = (providedKey ?? "source")
            .unicodeScalars.filter { validKey.contains($0) }
            .map { String($0) }.joined()
        let key = baseKey.isEmpty ? "source" : baseKey
        await engine.loadScript(trimmed, key: key)
        let meta = LXSourceEngine.parseMeta(trimmed, key: key)
        try? trimmed.write(to: fileURL(for: key), atomically: true, encoding: .utf8)
        await MainActor.run {
            sources.removeAll { $0.key == key }
            sources.append(meta)
            sources.sort { $0.key < $1.key }
            enabledKeys.insert(key)
            persistEnabled()
            lastError = nil
        }
        log.info("imported LX source \(key, privacy: .public) name=\(meta.name, privacy: .public)")
        return meta
    }

    func removeSource(_ key: String) {
        try? fm.removeItem(at: fileURL(for: key))
        sources.removeAll { $0.key == key }
        enabledKeys.remove(key)
        persistEnabled()
    }

    func setEnabled(_ key: String, enabled: Bool) {
        if enabled { enabledKeys.insert(key) } else { enabledKeys.remove(key) }
        persistEnabled()
    }

    private func persistEnabled() {
        UserDefaults.standard.set(Array(enabledKeys).sorted(), forKey: enabledKey)
    }

    private func loadPersisted() {
        guard let files = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        var loaded: [LXSourceMeta] = []
        for file in files where file.hasSuffix(".js") {
            let key = String(file.dropLast(3))
            guard let raw = try? String(contentsOf: fileURL(for: key), encoding: .utf8) else { continue }
            // 元信息从注释解析，不执行脚本（脚本在首次解析时懒加载）
            loaded.append(metaFromComment(raw, key: key))
        }
        sources = loaded.sorted { $0.key < $1.key }
    }

    private func metaFromComment(_ raw: String, key: String) -> LXSourceMeta {
        func field(_ name: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: "@\(name)\\s+(.+)", options: []),
                  let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let r = Range(m.range(at: 1), in: raw) else { return "" }
            return String(raw[r]).trimmingCharacters(in: .whitespaces)
        }
        return LXSourceMeta(key: key, name: field("name"), author: field("author"),
                            version: field("version"), description: field("description"), rawScript: raw)
    }

    /// 用已启用的音源依次尝试解析歌曲播放地址。返回第一个成功者。
    func resolve(track: Track, quality: String = "128k") async -> LXResolvedURL? {
        for key in enabledKeys.sorted() {
            guard let meta = sources.first(where: { $0.key == key }) else { continue }
            // 懒加载脚本到引擎（每次解析前 reload，避免脚本状态污染）
            await engine.loadScript(meta.rawScript, key: key)
            // 引擎会遍历该脚本上报的所有平台（kw/kg/tx/wy/mg...）
            if let result = try? await engine.resolve(musicInfo: track.lxMusicInfo, quality: quality) {
                log.info("LX resolved \(track.id) via \(key, privacy: .public) platform=\(result.sourceName, privacy: .public)")
                return result
            }
        }
        return nil
    }

    ///  dlopen 后各音源 support 的 quality 名称可能不同，这里统一映射 kumone 音质到 LX 音质。
    static func lxQuality(for audioQuality: String) -> String {
        switch audioQuality.lowercased() {
        case "exhigh", "h", "high": return "320k"
        case "lossless", "sq": return "flac"
        case "hires", "hr": return "flac24bit"
        default: return "128k"
        }
    }
}
