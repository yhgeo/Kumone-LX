import Foundation
import CryptoKit
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

    /// 生成唯一 key：优先用音源目录名（调用方传 providedKey，如 "flower"），
    /// 否则用 @name，再否则用脚本内容哈希。同名时追加序号，绝不覆盖已有音源。
    private func uniqueKey(_ provided: String?, raw: String, meta: LXSourceMeta) -> String {
        var base = (provided ?? meta.name)
            .unicodeScalars.filter { validKey.contains($0) }
            .map { String($0) }.joined()
        if base.isEmpty {
            let digest = Insecure.SHA1.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            base = "src" + String(digest.prefix(10))
        }
        var key = base
        var n = 2
        while sources.contains(where: { $0.key == key }) || fm.fileExists(atPath: fileURL(for: key).path) {
            key = "\(base)-\(n)"
            n += 1
        }
        return key
    }

    /// 从脚本原文导入一个音源。key 唯一，绝不覆盖已有音源。
    @discardableResult
    func importScript(_ raw: String, key providedKey: String? = nil) async -> LXSourceMeta? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run { lastError = "脚本内容为空" }
            return nil
        }
        let meta0 = LXSourceEngine.parseMeta(trimmed, key: "tmp")
        let key = uniqueKey(providedKey, raw: trimmed, meta: meta0)
        await engine.loadScript(trimmed, key: key)
        let meta = LXSourceEngine.parseMeta(trimmed, key: key)
        try? trimmed.write(to: fileURL(for: key), atomically: true, encoding: .utf8)
        await MainActor.run {
            if let idx = sources.firstIndex(where: { $0.key == key }) {
                sources[idx] = meta
            } else {
                sources.append(meta)
            }
            sources.sort { $0.key < $1.key }
            enabledKeys.insert(key)
            persistEnabled()
            lastError = nil
        }
        log.info("imported LX source \(key, privacy: .public) name=\(meta.name, privacy: .public)")
        return meta
    }

    /// 批量从 pdone/lx-music-source 导入全部音源。返回成功导入的数量。
    @discardableResult
    func importBatch(_ items: [(key: String, raw: String)]) async -> Int {
        var count = 0
        for item in items where !item.raw.trimmingCharacters(in: .whitespaces).isEmpty {
            if await importScript(item.raw, key: item.key) != nil { count += 1 }
        }
        return count
    }

    /// 一键导入：从 GitHub API 列出 pdone/lx-music-source 的所有音源目录，
    /// 逐个下载 latest.js 并导入。返回 (成功数, 总数, 失败原因列表)。
    func importAllFromGitHub() async -> (ok: Int, total: Int, failures: [String]) {
        let api = "https://api.github.com/repos/pdone/lx-music-source/contents"
        var request = URLRequest(url: URL(string: api)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let dirs: [[String: Any]]
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return (0, 0, ["仓库目录解析失败"])
            }
            dirs = arr.filter { ($0["type"] as? String) == "dir" }
        } catch {
            return (0, 0, ["获取音源列表失败：\(error.localizedDescription)"])
        }

        var items: [(key: String, raw: String)] = []
        var failures: [String] = []
        for dir in dirs {
            guard let name = dir["name"] as? String else { continue }
            // 目录项的 download_url 为 null，需拼 latest.js 的 raw 地址
            let jsURL = "https://raw.githubusercontent.com/pdone/lx-music-source/main/\(name)/latest.js"
            guard let url = URL(string: jsURL) else { continue }
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    failures.append("\(name): HTTP \(http.statusCode)")
                    continue
                }
                let raw = String(data: data, encoding: .utf8) ?? ""
                if raw.isEmpty { failures.append("\(name): 空内容"); continue }
                items.append((key: name, raw: raw))
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        let ok = await importBatch(items)
        return (ok, items.count, failures)
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
    /// 按启用顺序逐个尝试；每个音源最多 8 秒，避免单个慢音源拖垮播放。
    func resolve(track: Track, quality: String = "128k") async -> LXResolvedURL? {
        let diag = PlaybackDiagnostics.shared
        let keys = enabledKeys.sorted()
        diag.log("音源", "播放解析启用音源 \(keys.count) 个: \(keys.joined(separator: ","))")
        for key in keys {
            guard let meta = sources.first(where: { $0.key == key }) else { continue }
            let start = Date()
            await engine.loadScript(meta.rawScript, key: key)
            // 异步 inited 的音源给一点初始化时间
            try? await Task.sleep(for: .milliseconds(200))
            // 每个音源整体 8 秒超时（引擎内部实现，避免 Swift 并发 Sendable 问题）
            let result = try? await engine.resolve(musicInfo: track.lxMusicInfo, quality: quality, timeout: 8)
            let elapsed = Date().timeIntervalSince(start)
            if let result {
                diag.log("音源", "✓ \(meta.name) key=\(key) platform=\(result.sourceName) 耗时\(String(format:"%.1f",elapsed))s host=\(result.url.host() ?? "?")")
                return result
            } else {
                diag.log("音源", "✗ \(meta.name) key=\(key) 耗时\(String(format:"%.1f",elapsed))s 诊断=\(engine.diagnostic())")
            }
        }
        return nil
    }

    /// 音源可用性测试结果。
    struct TestResult: Identifiable {
        let id = UUID()
        let key: String
        let name: String
        let ok: Bool
        let elapsed: TimeInterval
        let platform: String?
        let message: String
    }

    /// 对单个音源做实测：加载脚本 -> 用样例歌解析 -> 记录平台/耗时/结果。
    func testSource(_ key: String) async -> TestResult {
        guard let meta = sources.first(where: { $0.key == key }) else {
            return TestResult(key: key, name: key, ok: false, elapsed: 0,
                              platform: nil, message: "未找到音源")
        }
        // 用一首大众歌曲做探针，各音源靠歌名/歌手匹配
        let sample: [String: Any] = [
            "id": "1295216600", "songId": "1295216600", "songid": "1295216600",
            "name": "晴天", "songname": "晴天",
            "singer": "周杰伦", "artist": "周杰伦",
            "duration": 269000,
        ]
        let start = Date()
        await engine.loadScript(meta.rawScript, key: key)
        // 部分音源（如野花）异步 send(inited)，给一点时间让初始化完成
        try? await Task.sleep(for: .milliseconds(600))
        let platformCount = engine.availableSources().count
        var ok = false
        var platform: String?
        var message: String
        if let result = try? await engine.resolve(musicInfo: sample, quality: "320k", timeout: 8) {
            ok = true
            platform = result.sourceName
            message = "解析成功：\(result.url.host() ?? result.url.absoluteString)"
        } else {
            let diag = engine.diagnostic()
            message = diag.isEmpty
                ? "解析失败（上报平台 \(platformCount) 个，音源未返回有效地址）"
                : diag
        }
        return TestResult(key: key,
                          name: meta.name.isEmpty ? key : meta.name,
                          ok: ok,
                          elapsed: Date().timeIntervalSince(start),
                          platform: platform,
                          message: message)
    }

    ///  dlopen 后各音源 support 的 quality 名称可能不同，这里统一映射 kumone 音质到 LX 音质。
    static func lxQuality(for audioQuality: String) -> String {
        switch audioQuality.lowercased() {
        case "hires", "hr": return "flac24bit"
        case "lossless", "sq": return "flac"
        // 标准/较高/极高 一律用 320k：绝大多数 lx 音源只配了 320k/128k，
        // 128k 在不少音源上不支持，导致"测试可用但播放跳过"。
        case "standard", "higher", "high", "exhigh", "h", "128k": return "320k"
        default: return "320k"
        }
    }
}
