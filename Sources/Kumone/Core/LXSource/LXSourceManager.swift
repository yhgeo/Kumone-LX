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
    @Published private(set) var enabledKeys: [String] = []
    /// 最近一次测试结果，按音源 key 索引，供设置页列表直接展示延迟/音质。
    @Published var testCache: [String: TestResult] = [:]
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
        enabledKeys = saved
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
            if !enabledKeys.contains(key) { enabledKeys.append(key) }
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
        enabledKeys.removeAll { $0 == key }
        persistEnabled()
    }

    func setEnabled(_ key: String, enabled: Bool) {
        if enabled { if !enabledKeys.contains(key) { enabledKeys.append(key) } } else { enabledKeys.removeAll { $0 == key } }
        persistEnabled()
    }

    private func persistEnabled() {
        UserDefaults.standard.set(enabledKeys, forKey: enabledKey)
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

    /// 验证音源返回的 URL 是否真的是可播音频，而不是网页/反爬提示/空响应。
    /// 用 Range 请求只取前 2KB，检查状态码与 Content-Type，避免整段下载。
    private func verifyAudioURL(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // 200 或 206 才算有效
            guard (200...206).contains(http.statusCode) else { return false }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            // 明确是网页/JSON 的一律拒绝（反爬、错误页、登录跳转）
            if contentType.contains("text/html") || contentType.contains("json")
                || contentType.contains("text/plain") { return false }
            // 有实体内容即可（音频常为 audio/* 或 application/octet-stream，
            // 有的音源不给 Content-Type，靠返回字节判断）
            return !data.isEmpty
        } catch {
            return false
        }
    }

    /// 用已启用的音源依次尝试解析歌曲播放地址。返回第一个「验证可播」者。
    /// 关键：音源返回的 URL 可能是无效网页/反爬地址（测试只看 scheme 会假阳性），
    /// 必须先验证再采用，否则 AVPlayer 加载失败就跳过整首歌。
    func resolve(track: Track, quality: String = "128k") async -> LXResolvedURL? {
        let diag = PlaybackDiagnostics.shared
        let keys = enabledKeys
        diag.log("音源", "播放解析启用音源 \(keys.count) 个: \(keys.joined(separator: ","))")
        for key in keys {
            guard let meta = sources.first(where: { $0.key == key }) else { continue }
            let start = Date()
            await engine.loadScript(meta.rawScript, key: key)
            // 异步 inited 的音源给一点初始化时间
            try? await Task.sleep(for: .milliseconds(200))
            // 每个音源整体 2 秒超时（引擎内部实现，避免 Swift 并发 Sendable 问题）
            let result = try? await engine.resolve(musicInfo: track.lxMusicInfo, quality: quality, timeout: 2)
            let elapsed = Date().timeIntervalSince(start)
            guard let result else {
                diag.log("音源", "✗ \(meta.name) key=\(key) 耗时\(String(format:"%.1f",elapsed))s 未返回URL")
                continue
            }
            // 验证 URL 真是音频，过滤假阳性（幻音等返回的无效地址）
            let valid = await verifyAudioURL(result.url)
            if valid {
                diag.log("音源", "✓ \(meta.name) key=\(key) platform=\(result.sourceName) 耗时\(String(format:"%.1f",elapsed))s host=\(result.url.host() ?? "?") 验证通过")
                return result
            } else {
                diag.log("音源", "✗ \(meta.name) key=\(key) 返回URL验证失败 host=\(result.url.host() ?? "?") 换下一个音源")
            }
        }
        return nil
    }

    /// 单个音质的测试结果（quality 为官方档位 key，显示用 displayName）。
    struct QualityResult: Identifiable {
        let id = UUID()
        let quality: String
        var displayName: String { AudioQuality(rawValue: quality)?.displayName ?? quality }
        let ok: Bool
        let elapsed: TimeInterval
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
        var qualityResults: [QualityResult] = []
    }

    /// 音源测试档位与官方音质设置完全一致（标准/较高/极高/无损/Hi-Res）。
    static let testQualities = AudioQuality.allCases.map(\.rawValue)

    /// 测试完成后应用结果：按"成功优先、延迟从低到高"重排启用顺序；
    /// 完全不通的音源自动取消启用。返回被禁用的音源名列表。
    @discardableResult
    func applyTestResults(_ results: [TestResult]) -> [String] {
        let okByKey = Dictionary(uniqueKeysWithValues: results.map { ($0.key, $0) })
        // 失败音源取消启用
        var disabled: [String] = []
        for r in results where !r.ok {
            if enabledKeys.contains(r.key) {
                enabledKeys.removeAll { $0 == r.key }
                disabled.append(r.name)
            }
        }
        // 成功音源按耗时升序排到前面
        enabledKeys.sort { a, b in
            let ra = okByKey[a], rb = okByKey[b]
            switch (ra?.ok, rb?.ok) {
            case (true, true): return ra!.elapsed < rb!.elapsed
            case (true, false): return true
            case (false, true): return false
            default: return a < b
            }
        }
        // sources 也按同一顺序排，UI 顺序 = 播放顺序
        sources.sort { a, b in
            let ia = enabledKeys.firstIndex(of: a.key) ?? Int.max
            let ib = enabledKeys.firstIndex(of: b.key) ?? Int.max
            return ia < ib
        }
        persistEnabled()
        return disabled
    }

    /// 按启用顺序排列的音源（UI 展示用）。
    var orderedSources: [LXSourceMeta] {
        sources.sorted { a, b in
            let ia = enabledKeys.firstIndex(of: a.key) ?? Int.max
            let ib = enabledKeys.firstIndex(of: b.key) ?? Int.max
            return ia == ib ? a.key < b.key : ia < ib
        }
    }

    /// 对单个音源做实测：加载脚本 -> 逐音质解析样例歌 -> 记录耗时/结果。
    func testSource(_ key: String) async -> TestResult {
        guard let meta = sources.first(where: { $0.key == key }) else {
            return TestResult(key: key, name: key, ok: false, elapsed: 0,
                              platform: nil, message: "未找到音源")
        }
        let sample: [String: Any] = [
            "id": "1295216600", "songId": "1295216600", "songid": "1295216600",
            "name": "晴天", "songname": "晴天",
            "singer": "周杰伦", "artist": "周杰伦",
            "duration": 269000,
        ]
        let start = Date()
        let diag = PlaybackDiagnostics.shared
        diag.log("测试", "开始测试音源 \(meta.name) key=\(key)")
        await engine.loadScript(meta.rawScript, key: key)
        // 异步 inited 的音源最多轮询 150ms 等平台上报，避免固定 300ms 浪费。
        for _ in 0..<3 where engine.availableSources().isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let platformCount = engine.availableSources().count
        diag.log("测试", "\(meta.name) 上报平台 \(platformCount) 个")

        var qualityResults: [QualityResult] = []
        var firstOK: LXResolvedURL?
        // 用官方五档逐档测；每档映射成 lx 音质值传给音源，显示用官方中文名。
        // 先测有损三档（标准/较高/极高），全失败则跳过无损两档。每档最多 2 秒。
        for (idx, q) in Self.testQualities.enumerated() {
            if idx >= 3, firstOK == nil { break }
            let qStart = Date()
            let lxQ = Self.lxQuality(for: q)
            if let result = try? await engine.resolve(musicInfo: sample, quality: lxQ, timeout: 2),
               await verifyAudioURL(result.url) {
                let e = Date().timeIntervalSince(qStart)
                qualityResults.append(QualityResult(quality: q, ok: true, elapsed: e))
                diag.log("测试", "\(meta.name) \(q)(\(lxQ)) ✓ \(String(format:"%.1f",e))s platform=\(result.sourceName)")
                if firstOK == nil { firstOK = result }
            } else {
                let e = Date().timeIntervalSince(qStart)
                qualityResults.append(QualityResult(quality: q, ok: false, elapsed: e))
                let d = engine.diagnostic()
                diag.log("测试", "\(meta.name) \(q)(\(lxQ)) ✗ \(String(format:"%.1f",e))s 验证失败/未返回 诊断=\(d)")
            }
        }

        let ok = firstOK != nil
        let supported = qualityResults.filter(\.ok).map(\.quality).joined(separator: "/")
        let message: String
        if ok {
            message = "支持音质：\(supported.isEmpty ? "？" : supported)"
                + (firstOK?.url.host().map { " · \($0)" } ?? "")
        } else {
            let diag = engine.diagnostic()
            message = diag.isEmpty
                ? "全部音质解析失败（上报平台 \(platformCount) 个）"
                : diag
        }
        let result = TestResult(key: key,
                                name: meta.name.isEmpty ? key : meta.name,
                                ok: ok,
                                elapsed: Date().timeIntervalSince(start),
                                platform: firstOK?.sourceName,
                                message: message,
                                qualityResults: qualityResults)
        // 立即缓存到管理器，设置页列表可实时显示延迟与音质。
        Task { @MainActor in self.testCache[key] = result }
        return result
    }

    ///  dlopen 后各音源 support 的 quality 名称可能不同，这里统一映射 kumone 音质到 LX 音质。
    static func lxQuality(for audioQuality: String) -> String {
        switch audioQuality.lowercased() {
        case "hires", "hr", "flac24bit": return "flac24bit"
        case "lossless", "sq", "flac": return "flac"
        // 官方五档与 lx 音质对齐：标准→128k，较高/极高→320k。
        // 极高与较高同为 320k（多数音源最高就 320k），无损/Hi-Res 用 flac。
        case "standard", "128k": return "128k"
        case "higher", "high", "exhigh", "h", "320k": return "320k"
        default: return "320k"
        }
    }
}
